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
