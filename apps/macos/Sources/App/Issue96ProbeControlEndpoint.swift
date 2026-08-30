import Darwin
import Foundation

/// Small, local-only, one-command-per-connection Unix-domain socket endpoint
/// for the opt-in Issue #96 probe. It is deliberately not part of the
/// production session/control protocol.
final class Issue96ProbeControlEndpoint: @unchecked Sendable {
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

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
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
        while bytes.count < 512 {
            var chunk = [UInt8](repeating: 0, count: min(128, 512 - bytes.count))
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
            let value = await handler(line)
            response.set(value)
        }
        let value = response.wait(timeout: 2) ?? "ERROR reason=command-timeout\n"
        write(value, to: client)
    }

    private static func write(_ value: String, to client: Int32) {
        let data = Data(value.utf8)
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            _ = Darwin.write(client, baseAddress, buffer.count)
        }
    }

    private enum EndpointError: Error {
        case pathTooLong
        case pathOccupied
        case systemCall(String)
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

    func wait(timeout: Int) -> String? {
        guard semaphore.wait(timeout: .now() + .seconds(timeout)) == .success else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
