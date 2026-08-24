import Foundation

public enum PluginPaths {
    private static var configuredHome: String? {
        let environment = ProcessInfo.processInfo.environment
        let value = environment["FORGE_DESKTOP_OPERATOR_HOME"] ?? environment["REPO_HARNESS_DESKTOP_OPERATOR_HOME"]
        guard let value, !value.isEmpty else { return nil }
        return NSString(string: value).expandingTildeInPath
    }

    public static var root: String {
        configuredHome ?? NSString(string: "~/Library/Application Support/Forge/DesktopOperator").expandingTildeInPath
    }

    public static var runDirectory: String {
        if configuredHome != nil {
            return URL(fileURLWithPath: root).appendingPathComponent("run").path
        }
        return NSString(string: "~/Library/Caches/Forge").expandingTildeInPath
    }

    public static var artifactDirectory: String { URL(fileURLWithPath: root).appendingPathComponent("artifacts").path }
    public static var logDirectory: String { URL(fileURLWithPath: root).appendingPathComponent("logs").path }
    public static var registrationDirectory: String { URL(fileURLWithPath: root).appendingPathComponent("registration").path }
    public static var sessionStorePath: String { URL(fileURLWithPath: root).appendingPathComponent("desktop-sessions.json").path }
    public static var defaultSocketPath: String { URL(fileURLWithPath: runDirectory).appendingPathComponent("desktop-operator.sock").path }

    public static func ensureRuntimeDirectories() throws {
        let manager = FileManager.default
        for path in [root, runDirectory, artifactDirectory, logDirectory, registrationDirectory] {
            try manager.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
}
