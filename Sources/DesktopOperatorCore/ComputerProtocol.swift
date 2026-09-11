import Foundation

public enum ComputerProviderProtocol {
    public static let executionMethod = "computer_execute"

    /// Compatibility-only protocol used by the pre-Unified-Element Computer surface.
    public static let legacyProtocolVersion = 1
    /// Version 2 adds provider-neutral element snapshots and semantic element actions.
    public static let elementProtocolVersion = 2
    /// Compatibility alias retained for existing Forge 1.x callers.
    public static let protocolVersion = legacyProtocolVersion

    public static let observeCapability = "computer.observe.v1"
    public static let inputCapability = "computer.input.v1"
    public static let consoleUnlockCapability = "computer.console.unlock.v1"
    public static let captureCapability = "computer.capture.v1"
    /// Compatibility marker only. Browser automation is no longer advertised through Unified Computer.
    public static let browserAutomationCompatibilityCapability = "computer.browser_automation.v1"

    public static let elementObserveCapability = "computer.element.observe.v2"
    public static let elementActionCapability = "computer.element.action.v2"

    public static let semanticElementActions = [
        "invoke",
        "focus",
        "set_value",
        "toggle",
        "expand",
        "collapse",
        "select",
        "open",
        "show_menu",
        "scroll_page_down",
        "scroll_page_up",
    ]

    public static let allCapabilities = [
        observeCapability,
        inputCapability,
        consoleUnlockCapability,
        captureCapability,
        elementObserveCapability,
        elementActionCapability,
    ]

    public static func expectedProtocolVersion(for capability: String) -> Int? {
        switch capability {
        case observeCapability, inputCapability, consoleUnlockCapability, captureCapability:
            return legacyProtocolVersion
        case elementObserveCapability, elementActionCapability:
            return elementProtocolVersion
        default:
            return nil
        }
    }
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

public struct ComputerElementObserveParams: Codable, Equatable, Sendable {
    public let interactionId: String
    public let maxDepth: Int?
    public let maxNodes: Int?
    public let includeValues: Bool?
    public let rootSelector: ElementSelector?

    public init(
        interactionId: String,
        maxDepth: Int? = nil,
        maxNodes: Int? = nil,
        includeValues: Bool? = nil,
        rootSelector: ElementSelector? = nil
    ) {
        self.interactionId = interactionId
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
        self.includeValues = includeValues
        self.rootSelector = rootSelector
    }
}

public struct ComputerElementActionParams: Codable, Equatable, Sendable {
    /// Exact target context returned with the observed element. v2 callers must round-trip it.
    public let target: ComputerElementTarget
    public let ref: String
    public let action: String
    public let value: JSONValue?

    public init(
        target: ComputerElementTarget,
        ref: String,
        action: String,
        value: JSONValue? = nil
    ) {
        self.target = target
        self.ref = ref
        self.action = action
        self.value = value
    }
}
