import Foundation

final class ComputerProviderRuntime {
    let browserAutomation: BrowserAutomationBroker
    private let browserMutationLock = NSRecursiveLock()

    init(browserAutomation: BrowserAutomationBroker) {
        self.browserAutomation = browserAutomation
    }

    var capabilities: [ComputerCapabilityRuntimeDescriptor] {
        [
            ComputerCapabilityRuntimeDescriptor(
                capabilityId: ComputerProviderProtocol.observeCapability,
                protocolVersion: ComputerProviderProtocol.protocolVersion,
                method: "execute",
                actions: ["desktop_observe"]
            ),
            ComputerCapabilityRuntimeDescriptor(
                capabilityId: ComputerProviderProtocol.inputCapability,
                protocolVersion: ComputerProviderProtocol.protocolVersion,
                method: "execute",
                actions: ["desktop_press", "desktop_type_text", "desktop_key"]
            ),
            ComputerCapabilityRuntimeDescriptor(
                capabilityId: ComputerProviderProtocol.captureCapability,
                protocolVersion: ComputerProviderProtocol.protocolVersion,
                method: "execute",
                actions: ["desktop_screenshot"]
            ),
            ComputerCapabilityRuntimeDescriptor(
                capabilityId: ComputerProviderProtocol.browserAutomationCapability,
                protocolVersion: ComputerProviderProtocol.protocolVersion,
                method: ComputerProviderProtocol.executionMethod,
                actions: BrowserAutomationBroker.supportedActions
            ),
        ]
    }

    func execute(_ params: ComputerExecuteParams) throws -> JSONValue {
        guard params.capability == ComputerProviderProtocol.browserAutomationCapability else {
            throw PluginError(
                code: "COMPUTER_CAPABILITY_UNSUPPORTED",
                message: "computer_execute does not expose capability \(params.capability)",
                retryable: false,
                domain: "computer"
            )
        }
        guard params.protocolVersion == ComputerProviderProtocol.protocolVersion else {
            throw PluginError(
                code: "COMPUTER_PROTOCOL_VERSION_UNSUPPORTED",
                message: "Unsupported Computer protocol version \(params.protocolVersion)",
                retryable: false,
                domain: "computer"
            )
        }
        return try executeBrowserAutomation(params.arguments)
    }

    func executeLegacyBrowserAutomation(_ params: JSONValue) throws -> JSONValue {
        guard params["protocolVersion"]?.intValue == LegacyBrowserAutomationProtocol.protocolVersion else {
            throw PluginError(
                code: "BROWSER_AUTOMATION_PROTOCOL_VERSION_MISMATCH",
                message: "Unsupported legacy browser automation protocol version",
                retryable: false,
                domain: "protocol"
            )
        }
        return try executeBrowserAutomation(params)
    }

    private func executeBrowserAutomation(_ params: JSONValue) throws -> JSONValue {
        let action = params["action"]?.stringValue
        if action == "metadata" || action == "list_tabs" || action == "capture_region" {
            return try browserAutomation.execute(params: params)
        }
        guard browserMutationLock.try() else {
            throw PluginError(
                code: "BROWSER_AUTOMATION_SERIALIZATION_BUSY",
                message: "Another browser mutation is still in progress; retry instead of waiting inside the Unix-socket request.",
                retryable: true,
                domain: "browser"
            )
        }
        defer { browserMutationLock.unlock() }
        return try browserAutomation.execute(params: params)
    }
}
