import Foundation

struct CLIOptions: Sendable {
    var port = AgentConfiguration.current.defaultPort
    var baud = AgentConfiguration.current.baudRate
    var duration: Double = 5
    var fps: Double = 10
    var hex = RGB.warm
}

struct SyncCLIOptions: Sendable {
    var port = AgentConfiguration.current.defaultPort
    var baud = AgentConfiguration.current.baudRate
    var fps = AgentConfiguration.current.defaultFPS
    var brightness = AgentConfiguration.current.defaultBrightness
    var duration: Double = 0
    var display = AgentConfiguration.current.defaultDisplay
    var captureScale = AgentConfiguration.current.defaultCaptureScale
    var statsInterval: Double = 0
}

@main
struct SkydimoAgent {
    static func main() async {
        do {
            try await run()
        } catch let error as AgentError {
            fputs("error: \(error.description)\n", stderr)
            Foundation.exit(1)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func run() async throws {
        var arguments = CommandLine.arguments.dropFirst()
        guard let command = arguments.first else {
            throw AgentError.usage(Usage.text)
        }
        arguments = arguments.dropFirst()

        switch command {
        case "version":
            print("SkydimoAgent 0.1.0")
        case "describe":
            try printDescription()
        case "displays":
            try await printDisplays()
        case "solid":
            let options = try parseOptions(Array(arguments))
            try await runSolid(options)
        case "off":
            let options = try parseOptions(Array(arguments))
            try await turnOff(options)
        case "sync":
            let options = try parseSyncOptions(Array(arguments))
            try await runSync(options)
        case "help", "--help", "-h":
            throw AgentError.usage(Usage.text)
        default:
            throw AgentError.usage("Unknown command: \(command)\n\n\(Usage.text)")
        }
    }

    private static func printDescription() throws {
        let configuration = AgentConfiguration.current
        let mapping = ScreenEdgeMapping.current

        struct Description: Encodable {
            let model: String
            let ledCount: Int
            let defaultPort: String
            let baudRate: Int32
            let defaultFPS: Double
            let defaultBrightness: Double
            let mapping: [String: [Int]]
        }

        let description = Description(
            model: configuration.model,
            ledCount: configuration.ledCount,
            defaultPort: configuration.defaultPort,
            baudRate: configuration.baudRate,
            defaultFPS: configuration.defaultFPS,
            defaultBrightness: configuration.defaultBrightness,
            mapping: [
                "right": [mapping.right.lowerBound, mapping.right.upperBound],
                "top": [mapping.top.lowerBound, mapping.top.upperBound],
                "left": [mapping.left.lowerBound, mapping.left.upperBound],
                "bottom": [mapping.bottom.lowerBound, mapping.bottom.upperBound],
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(description)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func runSolid(_ options: CLIOptions) async throws {
        let transport = SerialTransport(path: options.port, baudRate: options.baud)
        let runtime = AgentRuntime()
        try await runtime.sendSolid(
            transport: transport,
            color: options.hex,
            ledCount: AgentConfiguration.current.ledCount,
            fps: options.fps,
            duration: options.duration
        )
    }

    private static func turnOff(_ options: CLIOptions) async throws {
        let transport = SerialTransport(path: options.port, baudRate: options.baud)
        let runtime = AgentRuntime()
        try await runtime.turnOff(transport: transport, ledCount: AgentConfiguration.current.ledCount)
    }

    private static func printDisplays() async throws {
        let displays = try await ScreenCaptureSupport.displayDescriptors()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(displays)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func runSync(_ options: SyncCLIOptions) async throws {
        let transport = SerialTransport(path: options.port, baudRate: options.baud)
        let writer = FrameWriter(transport: transport)
        let syncOptions = SyncOptions(
            port: options.port,
            baud: options.baud,
            fps: options.fps,
            brightness: options.brightness,
            duration: options.duration,
            display: options.display,
            captureScale: options.captureScale,
            statsInterval: options.statsInterval
        )
        let session = try await makeSyncSession(writer: writer, options: syncOptions)
        defer {
            Task {
                await writer.turnOff(ledCount: AgentConfiguration.current.ledCount)
                await transport.closePort()
            }
        }
        try await session.run()
    }

    private static func makeSyncSession(writer: FrameWriter, options: SyncOptions) async throws -> SyncSession {
        let context = try await ScreenCaptureSupport.context(for: options.display)
        let scaledWidth = max(96, Int((Double(context.width) * options.captureScale).rounded()))
        let scaledHeight = max(96, Int((Double(context.height) * options.captureScale).rounded()))
        let session = StreamSyncSession(writer: writer, options: options, width: scaledWidth, height: scaledHeight)
        writer.setOnSent { [weak session] metrics in
            session?.recordWriteMetrics(metrics)
        }
        return session
    }

    private static func parseOptions(_ arguments: [String]) throws -> CLIOptions {
        var options = CLIOptions()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--port":
                index += 1
                guard index < arguments.count else {
                    throw AgentError.invalidArgument("--port requires a value")
                }
                options.port = arguments[index]
            case "--baud":
                index += 1
                guard index < arguments.count, let baud = Int32(arguments[index]) else {
                    throw AgentError.invalidArgument("--baud requires an integer value")
                }
                options.baud = baud
            case "--duration":
                index += 1
                guard index < arguments.count, let duration = Double(arguments[index]) else {
                    throw AgentError.invalidArgument("--duration requires a numeric value")
                }
                options.duration = duration
            case "--fps":
                index += 1
                guard index < arguments.count, let fps = Double(arguments[index]) else {
                    throw AgentError.invalidArgument("--fps requires a numeric value")
                }
                options.fps = fps
            case "--hex":
                index += 1
                guard index < arguments.count else {
                    throw AgentError.invalidArgument("--hex requires a value")
                }
                options.hex = try RGB(hex: arguments[index])
            default:
                throw AgentError.invalidArgument(argument)
            }
            index += 1
        }

        return options
    }

    private static func parseSyncOptions(_ arguments: [String]) throws -> SyncCLIOptions {
        var options = SyncCLIOptions()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--port":
                index += 1
                guard index < arguments.count else {
                    throw AgentError.invalidArgument("--port requires a value")
                }
                options.port = arguments[index]
            case "--baud":
                index += 1
                guard index < arguments.count, let baud = Int32(arguments[index]) else {
                    throw AgentError.invalidArgument("--baud requires an integer value")
                }
                options.baud = baud
            case "--fps":
                index += 1
                guard index < arguments.count, let fps = Double(arguments[index]) else {
                    throw AgentError.invalidArgument("--fps requires a numeric value")
                }
                options.fps = fps
            case "--brightness":
                index += 1
                guard index < arguments.count, let brightness = Double(arguments[index]) else {
                    throw AgentError.invalidArgument("--brightness requires a numeric value")
                }
                options.brightness = brightness
            case "--duration":
                index += 1
                guard index < arguments.count, let duration = Double(arguments[index]) else {
                    throw AgentError.invalidArgument("--duration requires a numeric value")
                }
                options.duration = duration
            case "--display":
                index += 1
                guard index < arguments.count, let display = Int(arguments[index]) else {
                    throw AgentError.invalidArgument("--display requires an integer value")
                }
                options.display = display
            case "--capture-scale":
                index += 1
                guard index < arguments.count, let captureScale = Double(arguments[index]) else {
                    throw AgentError.invalidArgument("--capture-scale requires a numeric value")
                }
                options.captureScale = captureScale
            case "--stats-interval":
                index += 1
                guard index < arguments.count, let statsInterval = Double(arguments[index]) else {
                    throw AgentError.invalidArgument("--stats-interval requires a numeric value")
                }
                options.statsInterval = statsInterval
            default:
                throw AgentError.invalidArgument(argument)
            }
            index += 1
        }

        return options
    }
}
