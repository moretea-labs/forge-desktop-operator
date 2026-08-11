import Darwin
import Foundation

public enum UnixSocketClient {
    public static func send(_ request: RPCRequest, to path: String, timeoutSeconds: Int = 10) throws -> RPCResponse {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw socketError("socket") }
        defer { Darwin.close(descriptor) }

        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

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
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw socketError("connect") }

        var payload = try JSONEncoder.repoHarness.encode(request)
        payload.append(0x0A)
        try writeAll(payload, to: descriptor)

        var response = Data()
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 0 {
                throw PluginError(code: "SOCKET_RESPONSE_MISSING", message: "Plugin closed the connection without a response", retryable: true, domain: "transport")
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw socketError("read")
            }
            if byte == 0x0A {
                return try JSONDecoder.repoHarness.decode(RPCResponse.self, from: response)
            }
            response.append(byte)
            if response.count > 16 * 1_024 * 1_024 {
                throw PluginError(code: "SOCKET_RESPONSE_TOO_LARGE", message: "Plugin response exceeded 16 MiB", domain: "transport")
            }
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
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
                throw PluginError(code: "SOCKET_WRITE_CLOSED", message: "Socket closed while writing request", retryable: true, domain: "transport")
            }
            offset += written
        }
    }

    private static func socketError(_ operation: String) -> PluginError {
        PluginError(code: "SOCKET_\(operation.uppercased())_FAILED", message: String(cString: strerror(errno)), retryable: true, domain: "transport")
    }
}
