import CoreMedia
import CoreVideo
import Dispatch
import Foundation
@preconcurrency import ScreenCaptureKit

struct SyncOptions: Sendable {
    var port = AgentConfiguration.current.defaultPort
    var baud = AgentConfiguration.current.baudRate
    var fps = AgentConfiguration.current.defaultFPS
    var brightness = AgentConfiguration.current.defaultBrightness
    var duration: Double = 0
    var display = AgentConfiguration.current.defaultDisplay
    var captureScale = AgentConfiguration.current.defaultCaptureScale
    var statsInterval: Double = 0
}

protocol SyncSession: AnyObject {
    func run() async throws
}

struct DisplayDescriptor: Encodable, Sendable {
    let index: Int
    let displayID: CGDirectDisplayID
    let pixelWidth: Int
    let pixelHeight: Int
    let pointWidth: Double
    let pointHeight: Double
    let pointPixelScale: Float
}

private struct PendingFrame: Sendable {
    let colors: [RGB]
    let timing: FrameTimingMetadata
    let shouldSend: Bool
}

final class FrameWriter: @unchecked Sendable {
    private let transport: SerialTransport
    private let lock = NSLock()
    private var latestFrame: PendingFrame?
    private var sendTask: Task<Void, Never>?
    private var onSent: (@Sendable (SentFrameMetrics) -> Void)?

    init(transport: SerialTransport) {
        self.transport = transport
    }

    func setOnSent(_ onSent: (@Sendable (SentFrameMetrics) -> Void)?) {
        lock.withLock {
            self.onSent = onSent
        }
    }

    func offer(colors: [RGB], timing: FrameTimingMetadata) {
        let shouldStart = lock.withLock { () -> Bool in
            latestFrame = PendingFrame(colors: colors, timing: timing, shouldSend: true)
            return sendTask == nil
        }
        if shouldStart {
            let task = Task { [weak self] in
                guard let self else { return }
                await self.drainLoop()
            }
            lock.withLock {
                sendTask = task
            }
        }
    }

    func turnOff(ledCount: Int) async {
        do {
            try await transport.write(frame: AdalightFrameEncoder.solidFrame(ledCount: ledCount, color: .off))
        } catch {
            fputs("serial off error: \(error)\n", stderr)
        }
    }

    private func drainLoop() async {
        while true {
            let pendingFrame: PendingFrame? = {
                lock.withLock { () -> PendingFrame? in
                    let frame = latestFrame
                    latestFrame = nil
                    return frame
                }
            }()

            guard let pendingFrame else {
                lock.withLock {
                    sendTask = nil
                }
                return
            }

            let frame = AdalightFrameEncoder.frame(colors: pendingFrame.colors)
            do {
                let writeStartedAt = ContinuousClock.now
                try await transport.write(frame: frame)
                let writeCompletedAt = ContinuousClock.now
                let sampleDurationMs = milliseconds(since: pendingFrame.timing.callbackReceivedAt, until: pendingFrame.timing.sampledAt)
                let queueDelayMs = milliseconds(since: pendingFrame.timing.sampledAt, until: writeStartedAt)
                let writeDurationMs = milliseconds(since: writeStartedAt, until: writeCompletedAt)
                let ageAtSendMs = milliseconds(since: pendingFrame.timing.sampledAt, until: writeCompletedAt)
                let totalPipelineMs = milliseconds(since: pendingFrame.timing.callbackReceivedAt, until: writeCompletedAt)
                let displayToSendMs = displayTimeToNowMilliseconds(pendingFrame.timing.displayTime, hostTime: mach_absolute_time())
                let onSent = lock.withLock { self.onSent }
                onSent?(SentFrameMetrics(
                    sampleDurationMs: sampleDurationMs,
                    queueDelayMs: queueDelayMs,
                    writeDurationMs: writeDurationMs,
                    ageAtSendMs: ageAtSendMs,
                    totalPipelineMs: totalPipelineMs,
                    displayToSendMs: displayToSendMs
                ))
            } catch {
                fputs("serial write error: \(error)\n", stderr)
            }
        }
    }
}

@MainActor
final class ScreenCaptureSupport {
    struct DisplayContext {
        let filter: SCContentFilter
        let width: Int
        let height: Int
        let pointWidth: Double
        let pointHeight: Double
        let pointPixelScale: Float
        let displayID: CGDirectDisplayID
    }

    static func displayContexts() async throws -> [DisplayContext] {
        let content = try await loadShareableContent()
        return content.displays.map(makeContext(from:))
    }

    static func displayDescriptors() async throws -> [DisplayDescriptor] {
        try await displayContexts().enumerated().map { index, context in
            DisplayDescriptor(
                index: index + 1,
                displayID: context.displayID,
                pixelWidth: context.width,
                pixelHeight: context.height,
                pointWidth: context.pointWidth,
                pointHeight: context.pointHeight,
                pointPixelScale: context.pointPixelScale
            )
        }
    }

    static func context(for index: Int) async throws -> DisplayContext {
        let contexts = try await displayContexts()
        guard index > 0, index <= contexts.count else {
            throw AgentError.invalidArgument("display index \(index) is out of range")
        }
        return contexts[index - 1]
    }

    private static func makeContext(from display: SCDisplay) -> DisplayContext {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let rect = filter.contentRect
        let scale = Double(filter.pointPixelScale)
        return DisplayContext(
            filter: filter,
            width: max(1, Int((rect.width * scale).rounded())),
            height: max(1, Int((rect.height * scale).rounded())),
            pointWidth: rect.width,
            pointHeight: rect.height,
            pointPixelScale: filter.pointPixelScale,
            displayID: display.displayID
        )
    }

    private static func loadShareableContent() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content {
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(throwing: AgentError.invalidArgument("ScreenCaptureKit returned no shareable content"))
                }
            }
        }
    }
}

final class StreamSyncSession: NSObject, SCStreamOutput, SCStreamDelegate, SyncSession, @unchecked Sendable {
    private let writer: FrameWriter
    private let options: SyncOptions
    private let sampler: EdgeSampler
    private let queue = DispatchQueue(label: "SkydimoAgent.SCStream", qos: .userInteractive)
    private var didLogFirstFrame = false
    private var statsLast = ContinuousClock.now
    private var statsFrames = 0
    private var statsCompleteFrames = 0
    private var statsIdleFrames = 0
    private var statsLatencyTotalMs = 0.0
    private var statsLatencySamples = 0
    private var statsLastLatencyMs = 0.0
    private var statsSampleTotalMs = 0.0
    private var statsSampleSamples = 0
    private var statsLastSampleMs = 0.0
    private var statsQueueTotalMs = 0.0
    private var statsQueueSamples = 0
    private var statsLastQueueMs = 0.0
    private var statsWriteTotalMs = 0.0
    private var statsWriteSamples = 0
    private var statsLastWriteMs = 0.0
    private var statsAgeAtSendTotalMs = 0.0
    private var statsAgeAtSendSamples = 0
    private var statsLastAgeAtSendMs = 0.0
    private var statsPipelineTotalMs = 0.0
    private var statsPipelineSamples = 0
    private var statsLastPipelineMs = 0.0
    private var statsDisplayToSendTotalMs = 0.0
    private var statsDisplayToSendSamples = 0
    private var statsLastDisplayToSendMs = 0.0

    init(writer: FrameWriter, options: SyncOptions, width: Int, height: Int) {
        self.writer = writer
        self.options = options
        self.sampler = EdgeSampler(width: width, height: height)
    }

    @MainActor
    func run() async throws {
        let context = try await ScreenCaptureSupport.context(for: options.display)
        let scaledWidth = max(96, Int((Double(context.width) * options.captureScale).rounded()))
        let scaledHeight = max(96, Int((Double(context.height) * options.captureScale).rounded()))
        let configuration = SCStreamConfiguration()
        configuration.width = scaledWidth
        configuration.height = scaledHeight
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, Int32(options.fps.rounded()))))
        configuration.captureResolution = .best
        configuration.backgroundColor = .clear
        configuration.ignoreShadowsDisplay = true

        // Try to prevent SCStream from throttling on static content
        if #available(macOS 14.0, *) {
            configuration.ignoreShadowsSingleWindow = true
        }
        if #available(macOS 14.2, *) {
            configuration.includeChildWindows = false
        }

        let stream = SCStream(filter: context.filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)

        fputs(
            "sync: starting capture display=\(options.display) width=\(scaledWidth) height=\(scaledHeight) brightness=\(options.brightness) fps=\(options.fps) capture_scale=\(options.captureScale)\n",
            stderr
        )
        try await stream.startCapture()
        fputs("sync: capture started\n", stderr)

        if options.duration > 0 {
            try await Task.sleep(nanoseconds: UInt64(options.duration * 1_000_000_000))
        } else {
            await SignalWatcher.waitForInterrupt()
        }

        try await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        guard let frameInfo = extractFrameInfo(from: sampleBuffer) else { return }
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        switch frameInfo.status {
        case .complete, .started:
            statsCompleteFrames += 1
        case .idle:
            statsIdleFrames += 1
        default:
            return
        }
        let callbackReceivedAt = ContinuousClock.now
        let colors = sampler.sample(pixelBuffer: pixelBuffer, brightness: options.brightness)
        let sampledAt = ContinuousClock.now
        recordLatency(frameInfo: frameInfo)

        if !didLogFirstFrame {
            didLogFirstFrame = true
            fputs(
                "sync: first frame right=\(averageHex(colors[Constants.rightRange.lowerBound - 1 ... Constants.rightRange.upperBound - 1])) top=\(averageHex(colors[Constants.topRange.lowerBound - 1 ... Constants.topRange.upperBound - 1])) left=\(averageHex(colors[Constants.leftRange.lowerBound - 1 ... Constants.leftRange.upperBound - 1])) bottom=\(averageHex(colors[Constants.bottomRange.lowerBound - 1 ... Constants.bottomRange.upperBound - 1]))\n",
                stderr
            )
        }

        statsFrames += 1
        emitStatsIfNeeded(colors: colors)
        writer.offer(colors: colors, timing: FrameTimingMetadata(
            callbackReceivedAt: callbackReceivedAt,
            sampledAt: sampledAt,
            displayTime: frameInfo.displayTime
        ))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("screen capture stopped: \(error)\n", stderr)
    }

    private func emitStatsIfNeeded(colors: [RGB]) {
        guard options.statsInterval > 0 else { return }
        let now = ContinuousClock.now
        let elapsed = now - statsLast
        let elapsedSeconds = Double(elapsed.components.seconds)
            + (Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000)
        guard elapsedSeconds >= options.statsInterval else { return }

        let sampleFPS = Double(statsFrames) / max(elapsedSeconds, 0.001)
        let completeFPS = Double(statsCompleteFrames) / max(elapsedSeconds, 0.001)
        let idleFPS = Double(statsIdleFrames) / max(elapsedSeconds, 0.001)
        let averageLatencyMs = statsLatencySamples > 0 ? (statsLatencyTotalMs / Double(statsLatencySamples)) : 0.0
        let averageSampleMs = statsSampleSamples > 0 ? (statsSampleTotalMs / Double(statsSampleSamples)) : 0.0
        let averageQueueMs = statsQueueSamples > 0 ? (statsQueueTotalMs / Double(statsQueueSamples)) : 0.0
        let averageWriteMs = statsWriteSamples > 0 ? (statsWriteTotalMs / Double(statsWriteSamples)) : 0.0
        let averageAgeAtSendMs = statsAgeAtSendSamples > 0 ? (statsAgeAtSendTotalMs / Double(statsAgeAtSendSamples)) : 0.0
        let averagePipelineMs = statsPipelineSamples > 0 ? (statsPipelineTotalMs / Double(statsPipelineSamples)) : 0.0
        let averageDisplayToSendMs = statsDisplayToSendSamples > 0 ? (statsDisplayToSendTotalMs / Double(statsDisplayToSendSamples)) : 0.0
        let right = averageHex(colors[Constants.rightRange.lowerBound - 1 ... Constants.rightRange.upperBound - 1])
        let top = averageHex(colors[Constants.topRange.lowerBound - 1 ... Constants.topRange.upperBound - 1])
        let left = averageHex(colors[Constants.leftRange.lowerBound - 1 ... Constants.leftRange.upperBound - 1])
        let bottom = averageHex(colors[Constants.bottomRange.lowerBound - 1 ... Constants.bottomRange.upperBound - 1])
        fputs(
            "stats: sample_fps=\(String(format: "%.2f", sampleFPS)) complete_fps=\(String(format: "%.2f", completeFPS)) idle_fps=\(String(format: "%.2f", idleFPS)) latency_ms=\(String(format: "%.1f", averageLatencyMs)) last_latency_ms=\(String(format: "%.1f", statsLastLatencyMs)) sample_ms=\(String(format: "%.1f", averageSampleMs)) last_sample_ms=\(String(format: "%.1f", statsLastSampleMs)) queue_ms=\(String(format: "%.1f", averageQueueMs)) last_queue_ms=\(String(format: "%.1f", statsLastQueueMs)) write_ms=\(String(format: "%.1f", averageWriteMs)) last_write_ms=\(String(format: "%.1f", statsLastWriteMs)) age_at_send_ms=\(String(format: "%.1f", averageAgeAtSendMs)) last_age_at_send_ms=\(String(format: "%.1f", statsLastAgeAtSendMs)) pipeline_ms=\(String(format: "%.1f", averagePipelineMs)) last_pipeline_ms=\(String(format: "%.1f", statsLastPipelineMs)) display_to_send_ms=\(String(format: "%.1f", averageDisplayToSendMs)) last_display_to_send_ms=\(String(format: "%.1f", statsLastDisplayToSendMs)) right=\(right) top=\(top) left=\(left) bottom=\(bottom)\n",
            stderr
        )
        statsLast = now
        statsFrames = 0
        statsCompleteFrames = 0
        statsIdleFrames = 0
        statsLatencyTotalMs = 0.0
        statsLatencySamples = 0
        statsSampleTotalMs = 0.0
        statsSampleSamples = 0
        statsQueueTotalMs = 0.0
        statsQueueSamples = 0
        statsWriteTotalMs = 0.0
        statsWriteSamples = 0
        statsAgeAtSendTotalMs = 0.0
        statsAgeAtSendSamples = 0
        statsPipelineTotalMs = 0.0
        statsPipelineSamples = 0
        statsDisplayToSendTotalMs = 0.0
        statsDisplayToSendSamples = 0
    }

    private func averageHex(_ slice: ArraySlice<RGB>) -> String {
        guard !slice.isEmpty else { return "000000" }
        let reds = slice.reduce(0) { $0 + Int($1.red) }
        let greens = slice.reduce(0) { $0 + Int($1.green) }
        let blues = slice.reduce(0) { $0 + Int($1.blue) }
        let count = slice.count
        return RGB(
            red: UInt8(reds / count),
            green: UInt8(greens / count),
            blue: UInt8(blues / count)
        ).hexString
    }

    private struct FrameInfo {
        let status: SCFrameStatus
        let displayTime: UInt64?
    }

    private func extractFrameInfo(from sampleBuffer: CMSampleBuffer) -> FrameInfo? {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusRawValue = attachments[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue)
        else {
            return nil
        }

        return FrameInfo(
            status: status,
            displayTime: attachments[.displayTime] as? UInt64
        )
    }

    private func recordLatency(frameInfo: FrameInfo) {
        guard let displayTime = frameInfo.displayTime else { return }
        guard let latencyMs = displayTimeToNowMilliseconds(displayTime) else { return }
        statsLastLatencyMs = latencyMs
        statsLatencyTotalMs += latencyMs
        statsLatencySamples += 1
    }

    func recordWriteMetrics(_ metrics: SentFrameMetrics) {
        queue.async { [weak self] in
            guard let self else { return }
            self.statsLastSampleMs = metrics.sampleDurationMs
            self.statsSampleTotalMs += metrics.sampleDurationMs
            self.statsSampleSamples += 1
            self.statsLastQueueMs = metrics.queueDelayMs
            self.statsQueueTotalMs += metrics.queueDelayMs
            self.statsQueueSamples += 1
            self.statsLastWriteMs = metrics.writeDurationMs
            self.statsWriteTotalMs += metrics.writeDurationMs
            self.statsWriteSamples += 1
            self.statsLastAgeAtSendMs = metrics.ageAtSendMs
            self.statsAgeAtSendTotalMs += metrics.ageAtSendMs
            self.statsAgeAtSendSamples += 1
            self.statsLastPipelineMs = metrics.totalPipelineMs
            self.statsPipelineTotalMs += metrics.totalPipelineMs
            self.statsPipelineSamples += 1
            if let displayToSendMs = metrics.displayToSendMs {
                self.statsLastDisplayToSendMs = displayToSendMs
                self.statsDisplayToSendTotalMs += displayToSendMs
                self.statsDisplayToSendSamples += 1
            }
        }
    }
}

enum SignalWatcher {
    static func waitForInterrupt() async {
        await withCheckedContinuation { continuation in
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)

            let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

            let resume = {
                intSource.cancel()
                termSource.cancel()
                continuation.resume()
            }

            intSource.setEventHandler(handler: resume)
            termSource.setEventHandler(handler: resume)
            intSource.resume()
            termSource.resume()
        }
    }
}
