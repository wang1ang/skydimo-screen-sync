import Foundation
import CoreGraphics

struct SampleRect: Equatable, Sendable {
    let x0: Double
    let y0: Double
    let x1: Double
    let y1: Double
}

struct PixelRect: Equatable, Sendable {
    let x0: Int
    let y0: Int
    let x1: Int
    let y1: Int
}

struct RGB: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    static let off = RGB(red: 0, green: 0, blue: 0)
    static let warm = RGB(red: 10, green: 5, blue: 0)

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(hex: String) throws {
        let raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else {
            throw AgentError.invalidHexColor(hex)
        }
        self.red = UInt8((value >> 16) & 0xFF)
        self.green = UInt8((value >> 8) & 0xFF)
        self.blue = UInt8(value & 0xFF)
    }

    var hexString: String {
        String(format: "%02X%02X%02X", red, green, blue)
    }
}

struct FrameTimingMetadata: Sendable {
    let callbackReceivedAt: ContinuousClock.Instant
    let sampledAt: ContinuousClock.Instant
    let displayTime: UInt64?
}

struct SentFrameMetrics: Sendable {
    let sampleDurationMs: Double
    let queueDelayMs: Double
    let writeDurationMs: Double
    let ageAtSendMs: Double
    let totalPipelineMs: Double
    let displayToSendMs: Double?
}

@inline(__always)
func milliseconds(since start: ContinuousClock.Instant, until end: ContinuousClock.Instant) -> Double {
    let elapsed = end - start
    return Double(elapsed.components.seconds) * 1000.0
        + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
}

@inline(__always)
func absoluteToSeconds(_ absolute: Int64, timebase: mach_timebase_info_data_t) -> Double {
    let nanos = (Double(absolute) * Double(timebase.numer)) / Double(timebase.denom)
    return nanos / 1_000_000_000.0
}

@inline(__always)
func displayTimeToNowMilliseconds(_ displayTime: UInt64?, hostTime: UInt64 = mach_absolute_time()) -> Double? {
    guard let displayTime else { return nil }
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let deltaAbsolute = Int64(bitPattern: hostTime) - Int64(bitPattern: displayTime)
    return max(0.0, absoluteToSeconds(deltaAbsolute, timebase: timebase) * 1000.0)
}

enum AgentError: Error, CustomStringConvertible {
    case usage(String)
    case invalidHexColor(String)
    case invalidArgument(String)
    case unsupportedBaudRate(Int32)
    case posix(function: String, code: Int32)

    var description: String {
        switch self {
        case .usage(let message):
            return message
        case .invalidHexColor(let value):
            return "Invalid hex color: \(value). Expected RRGGBB."
        case .invalidArgument(let value):
            return "Invalid argument: \(value)"
        case .unsupportedBaudRate(let value):
            return "Unsupported baud rate: \(value)"
        case .posix(let function, let code):
            let message = String(cString: strerror(code))
            return "\(function) failed: \(message) (\(code))"
        }
    }
}

enum Constants {
    static let model = "SK0L32"
    static let ledCount = 114
    static let defaultBaud: Int32 = 115_200
    static let defaultPort = "/dev/cu.usbserial-110"
    static let defaultFPS = 60.0
    static let defaultBrightness = 0.10
    static let defaultDisplay = 1
    static let defaultCaptureScale = 0.0625
    static let horizontalMarginSpaces = 2.0
    static let verticalMarginSpaces = 1.5
    static let topCount = 37
    static let bottomCount = 37
    static let leftCount = 20
    static let rightCount = 20
    static let rightRange = 1 ... 20
    static let topRange = 21 ... 57
    static let leftRange = 58 ... 77
    static let bottomRange = 78 ... 114
}

struct AgentConfiguration: Sendable {
    let model: String
    let ledCount: Int
    let baudRate: Int32
    let defaultFPS: Double
    let defaultBrightness: Double
    let defaultPort: String
    let defaultDisplay: Int
    let defaultCaptureScale: Double

    static let current = AgentConfiguration(
        model: Constants.model,
        ledCount: Constants.ledCount,
        baudRate: Constants.defaultBaud,
        defaultFPS: Constants.defaultFPS,
        defaultBrightness: Constants.defaultBrightness,
        defaultPort: Constants.defaultPort,
        defaultDisplay: Constants.defaultDisplay,
        defaultCaptureScale: Constants.defaultCaptureScale
    )
}

struct ScreenEdgeMapping: Sendable {
    let right: ClosedRange<Int>
    let top: ClosedRange<Int>
    let left: ClosedRange<Int>
    let bottom: ClosedRange<Int>

    static let current = ScreenEdgeMapping(
        right: Constants.rightRange,
        top: Constants.topRange,
        left: Constants.leftRange,
        bottom: Constants.bottomRange
    )
}

enum AdalightFrameEncoder {
    static func solidFrame(ledCount: Int, color: RGB) -> Data {
        let colors = Array(repeating: color, count: ledCount)
        return frame(colors: colors)
    }

    static func frame(colors: [RGB]) -> Data {
        precondition(colors.count > 0 && colors.count < 256, "LED count must be 1...255")
        var data = Data()
        data.append(contentsOf: [0x41, 0x64, 0x61, 0x00, 0x00, UInt8(colors.count)])
        for color in colors {
            data.append(color.red)
            data.append(color.green)
            data.append(color.blue)
        }
        return data
    }
}

struct Usage {
    static let text = """
    SkydimoAgent

    Usage:
      SkydimoAgent version
      SkydimoAgent describe
      SkydimoAgent displays
      SkydimoAgent solid --port /dev/cu.usbserial-110 --hex FFAA00 [--duration 5] [--fps 10] [--baud 115200]
      SkydimoAgent off --port /dev/cu.usbserial-110 [--baud 115200]
      SkydimoAgent sync --port /dev/cu.usbserial-110 [--display 1] [--fps 40] [--brightness 0.10] [--capture-scale 0.125] [--duration 0] [--stats-interval 0]

    Notes:
      - Uses ScreenCaptureKit (macOS 12.3+) for low-latency screen capture
      - Typical latency: 100-200ms glass-to-glass
    """
}
