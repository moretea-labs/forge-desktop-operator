import Foundation

public struct PluginManifest: Codable, Equatable, Sendable {
    public struct Transport: Codable, Equatable, Sendable {
        public let kind: String
        public let defaultSocket: String
    }

    public let id: String
    public let name: String
    public let version: String
    public let protocolVersion: String
    public let mode: String
    public let scope: String
    public let provider: String
    public let transport: Transport
    public let capabilities: [String]
    public let actions: [String]

    public static let current = PluginManifest(
        id: "desktop_operator",
        name: "Forge Desktop Operator",
        version: "0.2.2",
        protocolVersion: "1.0",
        mode: "external",
        scope: "controller",
        provider: "local-macos",
        transport: Transport(kind: "unix-socket-jsonl", defaultSocket: PluginPaths.defaultSocketPath),
        capabilities: [
            "desktop.status",
            "desktop.permissions",
            "desktop.session",
            "desktop.observe",
            "desktop.interact",
            "desktop.capture",
            "desktop.clipboard",
            "desktop.batch"
        ],
        actions: [
            "desktop_status",
            "desktop_permissions_request",
            "desktop_session_open",
            "desktop_observe",
            "desktop_press",
            "desktop_pointer_click",
            "desktop_type_text",
            "desktop_key",
            "desktop_clipboard_read",
            "desktop_clipboard_write",
            "desktop_copy",
            "desktop_paste",
            "desktop_open_url",
            "desktop_screenshot",
            "desktop_batch",
            "desktop_session_close"
        ]
    )
}

public struct HandshakeResult: Codable, Equatable, Sendable {
    public let protocolVersion: String
    public let supportedProtocolVersions: [String]
    public let pluginId: String
    public let pluginVersion: String
    public let processId: Int32
    public let startedAt: Date
    public let internalCapabilities: [String]
    public let browserAutomationProtocolVersion: Int
    public let browserAutomationActions: [String]
}

public enum DesktopOperatorIdentity {
    public static let bundleIdentifier = "com.moretea.forge.desktop-operator"
    public static let displayName = "Forge Desktop Operator"
    public static var bundlePath: String { Bundle.main.bundlePath }
}

public struct DesktopPermissionReadiness: Codable, Equatable, Sendable {
    public let service: String
    public let granted: Bool
    public let settingsPath: String
    public let requiredFor: [String]
    public let bundleIdentifier: String
    public let applicationName: String
    public let applicationPath: String
}

public enum DesktopPermissions {
    public static func accessibility(granted: Bool) -> DesktopPermissionReadiness {
        DesktopPermissionReadiness(
            service: "accessibility",
            granted: granted,
            settingsPath: "Privacy & Security > Accessibility",
            requiredFor: ["desktop_observe", "desktop_press", "desktop_pointer_click", "desktop_type_text", "desktop_key", "desktop_copy", "desktop_paste", "desktop_batch"],
            bundleIdentifier: DesktopOperatorIdentity.bundleIdentifier,
            applicationName: DesktopOperatorIdentity.displayName,
            applicationPath: DesktopOperatorIdentity.bundlePath
        )
    }

    public static func screenRecording(granted: Bool) -> DesktopPermissionReadiness {
        DesktopPermissionReadiness(
            service: "screen_recording",
            granted: granted,
            settingsPath: "Privacy & Security > Screen & System Audio Recording",
            requiredFor: ["desktop_screenshot"],
            bundleIdentifier: DesktopOperatorIdentity.bundleIdentifier,
            applicationName: DesktopOperatorIdentity.displayName,
            applicationPath: DesktopOperatorIdentity.bundlePath
        )
    }
}

public struct HealthResult: Codable, Equatable, Sendable {
    public let state: String
    public let checkedAt: Date
    public let platform: String
    public let accessibilityTrusted: Bool
    public let screenRecordingGranted: Bool
    public let activeSessionCount: Int
    public let socketPath: String
    public let providerBundleIdentifier: String
    public let providerApplicationPath: String
    public let permissions: [DesktopPermissionReadiness]
    public let internalCapabilities: [String]
    public let browserAutomationProtocolVersion: Int
    public let browserAutomationActions: [String]
    public let warnings: [String]
}
