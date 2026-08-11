import DesktopOperatorCore
import Foundation

func option(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

func printEncoded<T: Encodable>(_ value: T) throws {
    let data = try JSONEncoder.repoHarness.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

func parseJSON(_ raw: String?) throws -> JSONValue {
    guard let raw else { return .object([:]) }
    guard let data = raw.data(using: .utf8) else { throw PluginError.invalidArguments("Invalid UTF-8 JSON") }
    return try JSONDecoder.repoHarness.decode(JSONValue.self, from: data)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "help"

 do {
    switch command {
    case "serve":
        let path = option("--socket", in: arguments) ?? PluginPaths.defaultSocketPath
        try PluginPaths.ensureRuntimeDirectories()
        let runtime = PluginRuntime(socketPath: path)
        let server = UnixSocketServer(path: path, runtime: runtime)
        fputs("desktop-operator listening at \(path)\n", stderr)
        try server.run()
    case "manifest":
        try printEncoded(PluginManifest.current)
    case "health":
        let path = option("--socket", in: arguments) ?? PluginPaths.defaultSocketPath
        let runtime = PluginRuntime(socketPath: path)
        try printEncoded(runtime.health())
    case "doctor":
        let path = option("--socket", in: arguments) ?? PluginPaths.defaultSocketPath
        let runtime = PluginRuntime(socketPath: path)
        let output: JSONValue = .object([
            "manifest": try JSONValue.encode(PluginManifest.current),
            "health": try JSONValue.encode(runtime.health()),
            "paths": .object([
                "root": .string(PluginPaths.root),
                "socket": .string(path),
                "artifacts": .string(PluginPaths.artifactDirectory),
                "logs": .string(PluginPaths.logDirectory)
            ]),
            "socket_exists": .bool(FileManager.default.fileExists(atPath: path)),
            "executable": .string(CommandLine.arguments[0])
        ])
        try printEncoded(output)
    case "request":
        let path = option("--socket", in: arguments) ?? PluginPaths.defaultSocketPath
        let method = option("--method", in: arguments) ?? "handshake"
        let params = try parseJSON(option("--params-json", in: arguments))
        let request = RPCRequest(id: option("--id", in: arguments) ?? UUID().uuidString.lowercased(), method: method, params: params)
        try printEncoded(UnixSocketClient.send(request, to: path))
    case "execute":
        guard let action = option("--action", in: arguments) else { throw PluginError.invalidArguments("execute requires --action") }
        let path = option("--socket", in: arguments) ?? PluginPaths.defaultSocketPath
        let values = try parseJSON(option("--arguments-json", in: arguments))
        let params = try JSONValue.encode(ExecuteParams(action: action, arguments: values))
        let request = RPCRequest(id: UUID().uuidString.lowercased(), method: "execute", params: params)
        try printEncoded(UnixSocketClient.send(request, to: path))
    case "help", "--help", "-h":
        print("""
        Usage: desktop-operator <command> [options]

          serve [--socket PATH]                     Run the long-lived plugin service.
          doctor [--socket PATH]                    Print local readiness and paths.
          manifest                                  Print the static plugin manifest.
          health [--socket PATH]                    Print local health without connecting.
          request --method METHOD [--params-json]   Send a raw protocol request.
          execute --action ACTION [--arguments-json JSON]
        """)
    default:
        throw PluginError.invalidArguments("Unknown command \(command)")
    }
} catch let error as PluginError {
    try? printEncoded(error.payload)
    exit(2)
} catch {
    let payload = PluginError(code: "CLI_FAILED", message: error.localizedDescription, domain: "cli").payload
    try? printEncoded(payload)
    exit(2)
}
