import Darwin
import Foundation

actor SerialTransport {
    private let path: String
    private let baudRate: Int32
    private var fileDescriptor: Int32 = -1

    init(path: String, baudRate: Int32) {
        self.path = path
        self.baudRate = baudRate
    }

    deinit {
        if fileDescriptor >= 0 {
            close(fileDescriptor)
        }
    }

    func openIfNeeded() throws {
        guard fileDescriptor < 0 else { return }

        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            throw AgentError.posix(function: "open", code: errno)
        }

        do {
            try configure(fd: fd, baudRate: baudRate)

            let flags = fcntl(fd, F_GETFL)
            if flags >= 0 {
                _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
            }

            fileDescriptor = fd
        } catch {
            close(fd)
            throw error
        }
    }

    func write(frame: Data) throws {
        try openIfNeeded()
        try frame.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            var offset = 0

            while remaining > 0 {
                let written = Darwin.write(fileDescriptor, baseAddress.advanced(by: offset), remaining)
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw AgentError.posix(function: "write", code: errno)
                }
                remaining -= written
                offset += written
            }
        }

        if tcdrain(fileDescriptor) != 0 {
            throw AgentError.posix(function: "tcdrain", code: errno)
        }
    }

    func closePort() {
        guard fileDescriptor >= 0 else { return }
        close(fileDescriptor)
        fileDescriptor = -1
    }

    private func configure(fd: Int32, baudRate: Int32) throws {
        var options = termios()
        guard tcgetattr(fd, &options) == 0 else {
            throw AgentError.posix(function: "tcgetattr", code: errno)
        }

        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(CSIZE)
        options.c_cflag |= tcflag_t(CS8)
        options.c_cc.16 = 0
        options.c_cc.17 = 0

        let speed = try Self.speedConstant(for: baudRate)
        guard cfsetispeed(&options, speed) == 0 else {
            throw AgentError.posix(function: "cfsetispeed", code: errno)
        }
        guard cfsetospeed(&options, speed) == 0 else {
            throw AgentError.posix(function: "cfsetospeed", code: errno)
        }
        guard tcsetattr(fd, TCSANOW, &options) == 0 else {
            throw AgentError.posix(function: "tcsetattr", code: errno)
        }
    }

    private static func speedConstant(for baudRate: Int32) throws -> speed_t {
        switch baudRate {
        case 9_600: return speed_t(B9600)
        case 19_200: return speed_t(B19200)
        case 38_400: return speed_t(B38400)
        case 57_600: return speed_t(B57600)
        case 115_200: return speed_t(B115200)
        case 230_400: return speed_t(B230400)
        default:
            throw AgentError.unsupportedBaudRate(baudRate)
        }
    }
}
