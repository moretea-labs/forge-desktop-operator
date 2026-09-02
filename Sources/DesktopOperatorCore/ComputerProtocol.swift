import Foundation

public enum ComputerProviderProtocol {
    public static let executionMethod = "computer_execute"
    public static let protocolVersion = 1

    public static let observeCapability = "computer.observe.v1"
    public static let inputCapability = "computer.input.v1"
    public static let captureCapability = "computer.capture.v1"
    public static let browserAutomationCapability = "computer.browser_automation.v1"

    public static let allCapabilities = [
        observeCapability,
        inputCapability,
        captureCapability,
        browserAutomationCapability,
    ]
}

enum LegacyBrowserAutomationProtocol {
    static let method = "macos_browser_automation"
    static let capability = "macos_browser_automation.v1"
    static let protocolVersion = 1
}

public struct ComputerCapabilityRuntimeDescriptor: Codable, Equatable, Sendable {
    public let capabilityId: String
    public let protocolVersion: Int
    public let method: String
    public let actions: [String]

    public init(capabilityId: String, protocolVersion: Int, method: String, actions: [String]) {
        self.capabilityId = capabilityId
        self.protocolVersion = protocolVersion
        self.method = method
        self.actions = actions
    }
}

public struct ComputerExecuteParams: Codable, Equatable, Sendable {
    public let capability: String
    public let protocolVersion: Int
    public let arguments: JSONValue

    public init(capability: String, protocolVersion: Int, arguments: JSONValue = .object([:])) {
        self.capability = capability
        self.protocolVersion = protocolVersion
        self.arguments = arguments
    }
}
