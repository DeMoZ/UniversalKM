import Darwin
import Foundation

/// Raw USB-CDC serial port (design D5). Non-blocking descriptor; incoming bytes arrive through a
/// DispatchSourceRead on the owner's queue. All methods must be called on that queue.
final class SerialPort: @unchecked Sendable {
    let path: String
    private let queue: DispatchQueue
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?

    /// Called on the queue with each chunk read.
    var onData: (([UInt8]) -> Void)?
    /// Called on the queue once when the device goes away or reading fails.
    var onClose: (() -> Void)?

    init(path: String, queue: DispatchQueue) {
        self.path = path
        self.queue = queue
    }

    var isOpen: Bool { fd >= 0 }

    func open() throws {
        let descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // Exclusive: a second program (the official client) cannot interleave frames with ours.
        if ioctl(descriptor, TIOCEXCL) != 0 {
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EBUSY)
        }
        var settings = termios()
        tcgetattr(descriptor, &settings)
        cfmakeraw(&settings)
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
        cfsetspeed(&settings, speed_t(B115200))   // nominal for USB-CDC
        tcsetattr(descriptor, TCSANOW, &settings)
        tcflush(descriptor, TCIOFLUSH)
        fd = descriptor

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { Darwin.close(descriptor) }
        self.source = source
        source.resume()
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if count > 0 {
            onData?(Array(buffer[0..<count]))
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            closeAndNotify()
        }
    }

    /// Writes all bytes. Frames are small, so a full output buffer is waited out briefly.
    @discardableResult
    func write(_ bytes: [UInt8]) -> Bool {
        guard fd >= 0 else { return false }
        var offset = 0
        var waits = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                offset += written
            } else if written < 0 && (errno == EAGAIN || errno == EINTR) && waits < 50 {
                waits += 1
                usleep(200)
            } else {
                closeAndNotify()
                return false
            }
        }
        return true
    }

    /// Blocking read of whatever arrives within `timeout` (for the synchronous exit path), bypassing
    /// the read source: the caller is on the queue, so the source cannot run meanwhile.
    func readBlocking(timeout: TimeInterval) -> [UInt8] {
        guard fd >= 0 else { return [] }
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, Int32(max(0, timeout) * 1000)) > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        return count > 0 ? Array(buffer[0..<count]) : []
    }

    func close() {
        guard fd >= 0 else { return }
        fd = -1
        source?.cancel()
        source = nil
    }

    private func closeAndNotify() {
        guard fd >= 0 else { return }
        close()
        onClose?()
    }
}
