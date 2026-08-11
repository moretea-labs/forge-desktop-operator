import Darwin
import Foundation

public final class UnixSocketServer: @unchecked Sendable {
    private let path: String
    private let runtime: PluginRuntime
    private var serverDescriptor: Int32 = -1
    private var lockDescriptor: Int32 = -1
    private let clientQueue = DispatchQueue(label: "com.moretea.forge.desktop-operator.clients", attributes: .concurrent)

    public init(path: String, runtime: PluginRuntime) {
        self.path = path
        self.runtime = runtime
    }

    deinit { stop() }

    public func run() throws {
        try PluginPaths.ensureRuntimeDirectories()
        try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try acquireInstanceLock()
        unlink(path)
        serverDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverDescriptor >= 0 else { throw socketError("socket") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw PluginError(code: "SOCKET_PATH_TOO_LONG", message: "Unix socket path exceeds sockaddr_un capacity", domain: "transport")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            let destination = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self)
            for (index, byte) in bytes.enumerated() { destination[index] = byte }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(serverDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { throw socketError("bind") }
        chmod(path, 0o600)
        guard listen(serverDescriptor, 16) == 0 else { throw socketError("listen") }

        while !runtime.shutdownRequested {
            let client = accept(serverDescriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                throw socketError("accept")
            }
            clientQueue.async { [self] in
                handleClient(client)
            }
        }
        stop()
    }

    public func stop() {
        if serverDescriptor >= 0 {
            Darwin.close(serverDescriptor)
            serverDescriptor = -1
        }
        unlink(path)
        if lockDescriptor >= 0 {
            flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
            lockDescriptor = -1
        }
    }

    private func handleClient(_ descriptor: Int32) {
        defer { Darwin.close(descriptor) }
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 8_192)

        while !runtime.shutdownRequested {
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            pending.append(contentsOf: chunk.prefix(count))
            if pending.count > 16 * 1_024 * 1_024 { return }

            while let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard !line.isEmpty else { continue }

                let response: RPCResponse
                do {
                    let request = try JSONDecoder.repoHarness.decode(RPCRequest.self, from: line)
                    response = runtime.handle(request)
                } catch {
                    response = RPCResponse(id: "unknown", error: PluginError(code: "INVALID_REQUEST", message: error.localizedDescription, domain: "protocol"))
                }

                do {
                    var encoded = try JSONEncoder.repoHarness.encode(response)
                    encoded.append(0x0A)
                    try writeAll(encoded, to: descriptor)
                } catch {
                    return
                }
                if runtime.shutdownRequested { return }
            }
        }
    }

    private func acquireInstanceLock() throws {
        let lockPath = path + ".lock"
        lockDescriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockDescriptor >= 0 else { throw socketError("lock_open") }
        guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lockDescriptor)
            lockDescriptor = -1
            throw PluginError(code: "SOCKET_ALREADY_ACTIVE", message: "Another desktop-operator instance owns \(path)", retryable: true, domain: "transport")
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw socketError("write")
            }
            if written == 0 {
                throw PluginError(code: "SOCKET_WRITE_CLOSED", message: "Socket closed while writing response", retryable: true, domain: "transport")
            }
            offset += written
        }
    }

    private func socketError(_ operation: String) -> PluginError {
        PluginError(code: "SOCKET_\(operation.uppercased())_FAILED", message: String(cString: strerror(errno)), retryable: true, domain: "transport")
    }
}
