import Darwin
import Foundation

/// Validates a line before handing it to the harness. Invalid input is
/// rejected before any AppKit handler can run.
enum Issue96ProbeEndpointExecution {
    static func execute(
        line: String,
        handler: @escaping @Sendable (String) async -> String) async -> String {
        guard Issue96ProbeCommand.parse(line) != nil else {
            return "ERROR reason=unsupported-command\n"
        }
        return await handler(line)
    }
}

/// Small, local-only, one-command-per-connection Unix-domain socket endpoint
/// for the opt-in Issue #96 probe. It is deliberately not part of the
/// production session/control protocol.
final class Issue96ProbeControlEndpoint: @unchecked Sendable {
    static let maximumInputBytes = 512
    static let inputReadTimeoutSeconds = 2

    private let path: String
    private let stateLock = NSLock()
    private let connectionSlots = DispatchSemaphore(value: 4)
    private var listener: DispatchSourceRead?
    private var ownsSocketPath = false

    init(path: String) {
        self.path = path
    }

    func start(handler: @escaping @Sendable (String) async -> String) throws {
        var address = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw EndpointError.pathTooLong
        }
        try prepareSocketPath()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EndpointError.systemCall("socket") }

        do {
            address = sockaddr_un()
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            address.sun_family = sa_family_t(AF_UNIX)
            _ = path.withCString { source in
                withUnsafeMutablePointer(to: &address.sun_path) { destination in
                    memcpy(destination, source, path.utf8.count + 1)
                }
            }

            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0 else { throw EndpointError.systemCall("bind") }
            guard chmod(path, mode_t(0o600)) == 0 else {
                throw EndpointError.systemCall("chmod")
            }
            guard listen(fd, 4) == 0 else { throw EndpointError.systemCall("listen") }

            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw EndpointError.systemCall("fcntl")
            }

            let source = DispatchSource.makeReadSource(
                fileDescriptor: fd,
                queue: DispatchQueue.global(qos: .utility))
            source.setEventHandler { [weak self] in
                self?.acceptConnections(on: fd, handler: handler)
            }
            source.setCancelHandler {
                close(fd)
            }

            stateLock.lock()
            listener = source
            ownsSocketPath = true
            stateLock.unlock()
            source.resume()
        } catch {
            close(fd)
            unlink(path)
            throw error
        }
    }

    func stop() {
        stateLock.lock()
        let source = listener
        listener = nil
        let shouldUnlink = ownsSocketPath
        ownsSocketPath = false
        stateLock.unlock()

        source?.cancel()
        if shouldUnlink {
            unlink(path)
        }
    }

    deinit {
        stop()
    }

    private func prepareSocketPath() throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: nil)

        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFSOCK else {
                throw EndpointError.pathOccupied
            }
            guard unlink(path) == 0 else { throw EndpointError.systemCall("unlink") }
        } else if errno != ENOENT {
            throw EndpointError.systemCall("lstat")
        }
    }

    private func acceptConnections(
        on fd: Int32,
        handler: @escaping @Sendable (String) async -> String) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            Self.preventSigPipe(on: client)
            guard connectionSlots.wait(timeout: .now()) == .success else {
                Self.write("ERROR reason=endpoint-busy\n", to: client)
                shutdown(client, SHUT_RDWR)
                close(client)
                continue
            }
            DispatchQueue.global(qos: .utility).async {
                defer { self.connectionSlots.signal() }
                Self.handle(client: client, handler: handler)
            }
        }
    }

    private static func handle(
        client: Int32,
        handler: @escaping @Sendable (String) async -> String) {
        defer {
            shutdown(client, SHUT_RDWR)
            close(client)
        }

        var timeout = timeval(tv_sec: Self.inputReadTimeoutSeconds, tv_usec: 0)
        withUnsafePointer(to: &timeout) { pointer in
            _ = setsockopt(
                client,
                SOL_SOCKET,
                SO_RCVTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size))
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        while bytes.count < Self.maximumInputBytes {
            var chunk = [UInt8](
                repeating: 0,
                count: min(128, Self.maximumInputBytes - bytes.count))
            let count = chunk.withUnsafeMutableBytes { buffer in
                read(client, buffer.baseAddress, buffer.count)
            }
            guard count > 0 else { break }
            bytes.append(contentsOf: chunk.prefix(count))
            if bytes.contains(10) { break }
        }
        guard !bytes.isEmpty, let line = String(bytes: bytes, encoding: .utf8) else {
            write("ERROR reason=empty-command\n", to: client)
            return
        }

        let response = BlockingAsyncResult()
        Task.detached {
            let value = await Issue96ProbeEndpointExecution.execute(line: line, handler: handler)
            response.set(value)
        }
        // Do not impose an execution timeout here. A timeout response would
        // detach the operator-visible result from a task that could still
        // execute the AppKit primitive later. The socket input read above is
        // independently bounded; once a valid command is accepted, this
        // worker waits for the definitive handler result.
        let value = response.wait()
        write(value, to: client)
    }

    private static func write(_ value: String, to client: Int32) {
        let data = Data(value.utf8)
        _ = Issue96ProbeSocketWriter.writeAll(data, to: client, write: Darwin.write)
    }

    private static func preventSigPipe(on client: Int32) {
        var value: Int32 = 1
        _ = withUnsafePointer(to: &value) { pointer in
            setsockopt(
                client,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                pointer,
                socklen_t(MemoryLayout<Int32>.size))
        }
    }

    private enum EndpointError: Error {
        case pathTooLong
        case pathOccupied
        case systemCall(String)
    }
}

enum Issue96ProbeSocketWriter {
    typealias WriteCall = (Int32, UnsafeRawPointer?, Int) -> Int

    @discardableResult
    static func writeAll(
        _ data: Data,
        to client: Int32,
        write: WriteCall) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return true }

            var offset = 0
            while offset < buffer.count {
                let written = write(
                    client,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}

private final class BlockingAsyncResult: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var value: String?

    func set(_ value: String) {
        lock.lock()
        self.value = value
        lock.unlock()
        semaphore.signal()
    }

    func wait() -> String {
        semaphore.wait()
        lock.lock()
        defer { lock.unlock() }
        return value ?? "ERROR reason=execution-result-unavailable\n"
    }
}
