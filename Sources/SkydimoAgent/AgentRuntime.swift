import Foundation

enum AgentStatus: String, Sendable {
    case idle
    case sendingSolid
}

actor AgentRuntime {
    private(set) var status: AgentStatus = .idle

    func sendSolid(
        transport: SerialTransport,
        color: RGB,
        ledCount: Int,
        fps: Double,
        duration: TimeInterval
    ) async throws {
        status = .sendingSolid
        defer { status = .idle }

        let frame = AdalightFrameEncoder.solidFrame(ledCount: ledCount, color: color)
        let interval = fps > 0 ? 1.0 / fps : 0.0
        let deadline = duration > 0 ? Date().timeIntervalSinceReferenceDate + duration : nil

        while true {
            try await transport.write(frame: frame)

            if let deadline, Date().timeIntervalSinceReferenceDate >= deadline {
                break
            }

            if interval <= 0 {
                break
            }

            let nanoseconds = UInt64(interval * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    }

    func turnOff(transport: SerialTransport, ledCount: Int) async throws {
        status = .idle
        try await transport.write(frame: AdalightFrameEncoder.solidFrame(ledCount: ledCount, color: .off))
    }
}
