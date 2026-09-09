import Foundation

public struct DesktopFrame: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

public struct DesktopWindow: Codable, Equatable, Sendable {
    public let windowId: UInt32
    public let pid: Int32
    public let ownerName: String
    public let title: String?
    public let layer: Int
    public let alpha: Double
    public let onScreen: Bool
    public let frame: DesktopFrame?
}

public struct AXNode: Codable, Equatable, Sendable {
    public let ref: String
    public let role: String?
    public let subrole: String?
    public let title: String?
    public let identifier: String?
    public let description: String?
    public let value: JSONValue?
    public let enabled: Bool?
    public let focused: Bool?
    public let selected: Bool?
    public let expanded: Bool?
    public let frame: DesktopFrame?
    public let actions: [String]
    public let children: [AXNode]
}

public struct AccessibilitySnapshot: Codable, Equatable, Sendable {
    public let interactionId: String
    public let snapshotRevision: Int
    public let capturedAt: Date
    public let truncated: Bool
    public let nodeCount: Int
    public let root: AXNode
}

public struct ComputerElementTarget: Codable, Equatable, Sendable {
    public let interactionId: String
    public let pid: Int32
    public let bundleIdentifier: String?
    public let appName: String
    /// Provider-local AX window ref inside this observation epoch. It is not a durable window identity.
    public let windowRef: String?
    public let snapshotRevision: Int
}

public struct ComputerElementState: Codable, Equatable, Sendable {
    public let enabled: Bool?
    public let focused: Bool?
    public let selected: Bool?
    public let expanded: Bool?
}

public struct ComputerElement: Codable, Equatable, Sendable {
    /// Provider-local element ref valid only for target.snapshotRevision.
    public let ref: String
    public let target: ComputerElementTarget
    public let role: String?
    public let subrole: String?
    public let name: String?
    public let identifier: String?
    public let description: String?
    public let value: JSONValue?
    public let state: ComputerElementState
    /// Observed geometry only. Bounds are never identity and never authorize pointer input.
    public let bounds: DesktopFrame?
    /// Provider-neutral semantic actions supported by this observation.
    public let actions: [String]
    public let children: [ComputerElement]
}

public struct ComputerElementSnapshot: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let interactionId: String
    public let snapshotRevision: Int
    public let pid: Int32
    public let bundleIdentifier: String?
    public let appName: String
    public let capturedAt: Date
    public let truncated: Bool
    public let nodeCount: Int
    public let root: ComputerElement
}

public struct ElementSelector: Codable, Equatable, Sendable {
    public let ref: String?
    public let role: String?
    public let title: String?
    public let identifier: String?

    public init(ref: String? = nil, role: String? = nil, title: String? = nil, identifier: String? = nil) {
        self.ref = ref
        self.role = role
        self.title = title
        self.identifier = identifier
    }
}

public struct ScreenshotResult: Codable, Equatable, Sendable {
    public let artifactPath: String
    public let scope: String
    public let windowId: UInt32?
    public let capturedAt: Date
    public let byteCount: Int
}
