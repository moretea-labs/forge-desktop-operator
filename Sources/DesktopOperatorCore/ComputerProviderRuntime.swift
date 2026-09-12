import Foundation

final class ComputerProviderRuntime {
    typealias NativeActionExecutor = (_ action: String, _ arguments: JSONValue) throws -> JSONValue
    typealias ElementExecutor = (_ arguments: JSONValue) throws -> JSONValue

    /// Explicit migration-only bridge. It is not part of the Unified Computer capability advertisement.
    private let legacyBrowserCompatibility: BrowserAutomationBroker
    private let legacyBrowserMutationLock = NSRecursiveLock()

    init(browserAutomation: BrowserAutomationBroker) {
        self.legacyBrowserCompatibility = browserAutomation
    }

    var capabilities: [ComputerCapabilityRuntimeDescriptor] {
        [
            ComputerCapabilityRuntimeDescriptor(
                capabilityId: ComputerProviderProtocol.observeCapability,
                protocolVersion: ComputerProviderProtocol.legacyProtocolVersion,
                method: ComputerProviderProtocol.executionMethod,
                actions: ["desktop_observe"]
            ),
            ComputerCapabilityRuntimeDescriptor(
                capabilityId: ComputerProviderProtocol.inputCapability,
                protocolVersion: ComputerProviderProtocol.legacyProtocolVersion,
                method: ComputerProviderProtocol.executionMethod,
                actions: ["desktop_press", "desktop_select_rows", "desktop_pointer_click", "desktop_type_text", "desktop_key", "desktop_open_url"]
            ),
            ComputerCapabilityRuntimeDescriptor(
                capabilityId: ComputerProviderProtocol.consoleUnlockCapability,
                protocolVersion: ComputerProviderProtocol.legacyProtocolVersion,
                method: ComputerProviderProtocol.executionMethod,
                actions: ["prepare_unlock_console", "unlock_console"]
            ),
            ComputerCapabilityRuntimeDescriptor(
                capabilityId: ComputerProviderProtocol.captureCapability,
                protocolVersion: ComputerProviderProtocol.legacyProtocolVersion,
                method: ComputerProviderProtocol.executionMethod,
                actions: ["desktop_screenshot"]
            ),
            ComputerCapabilityRuntimeDescriptor(
                capabilityId: ComputerProviderProtocol.elementObserveCapability,
                protocolVersion: ComputerProviderProtocol.elementProtocolVersion,
                method: ComputerProviderProtocol.executionMethod,
                actions: ["observe_elements"]
            ),
            ComputerCapabilityRuntimeDescriptor(
                capabilityId: ComputerProviderProtocol.elementActionCapability,
                protocolVersion: ComputerProviderProtocol.elementProtocolVersion,
                method: ComputerProviderProtocol.executionMethod,
                actions: ComputerProviderProtocol.semanticElementActions
            ),
        ]
    }

    func execute(
        _ params: ComputerExecuteParams,
        nativeAction: NativeActionExecutor,
        elementObserve: ElementExecutor,
        elementAction: ElementExecutor,
        consoleUnlock: ElementExecutor = { _ in
            throw PluginError(code: "CONSOLE_UNLOCK_EXECUTOR_UNAVAILABLE", message: "Console unlock executor is unavailable.", retryable: false, domain: "computer")
        }
    ) throws -> JSONValue {
        guard let expectedVersion = ComputerProviderProtocol.expectedProtocolVersion(for: params.capability) else {
            throw PluginError(
                code: "COMPUTER_CAPABILITY_UNSUPPORTED",
                message: "computer_execute does not expose capability \(params.capability)",
                retryable: false,
                domain: "computer"
            )
        }
        guard params.protocolVersion == expectedVersion else {
            throw PluginError(
                code: "COMPUTER_PROTOCOL_VERSION_UNSUPPORTED",
                message: "Capability \(params.capability) requires Computer protocol version \(expectedVersion), got \(params.protocolVersion)",
                retryable: false,
                domain: "computer"
            )
        }

        switch params.capability {
        case ComputerProviderProtocol.consoleUnlockCapability:
            guard let action = params.arguments["action"]?.stringValue,
                  ["prepare_unlock_console", "unlock_console"].contains(action) else {
                throw PluginError(code: "COMPUTER_ACTION_UNSUPPORTED", message: "computer.console.unlock.v1 exposes prepare_unlock_console and unlock_console only", retryable: false, domain: "computer")
            }
            return try consoleUnlock(params.arguments)
        case ComputerProviderProtocol.elementObserveCapability:
            return try elementObserve(params.arguments)
        case ComputerProviderProtocol.elementActionCapability:
            guard let action = params.arguments["action"]?.stringValue,
                  ComputerProviderProtocol.semanticElementActions.contains(action) else {
                throw PluginError(
                    code: "COMPUTER_ACTION_UNSUPPORTED",
                    message: "computer.element.action.v2 requires one declared semantic action",
                    retryable: false,
                    domain: "computer"
                )
            }
            return try elementAction(params.arguments)
        case ComputerProviderProtocol.observeCapability,
             ComputerProviderProtocol.inputCapability,
             ComputerProviderProtocol.captureCapability:
            guard let action = params.arguments["action"]?.stringValue else {
                throw PluginError.invalidArguments("Computer v1 native capability requires arguments.action")
            }
            let descriptor = capabilities.first { $0.capabilityId == params.capability }
            guard descriptor?.actions.contains(action) == true else {
                throw PluginError(
                    code: "COMPUTER_ACTION_UNSUPPORTED",
                    message: "Action \(action) is not exposed by capability \(params.capability)",
                    retryable: false,
                    domain: "computer"
                )
            }
            var object = params.arguments.objectValue ?? [:]
            object.removeValue(forKey: "action")
            return try nativeAction(action, .object(object))
        default:
            throw PluginError(
                code: "COMPUTER_CAPABILITY_UNSUPPORTED",
                message: "computer_execute does not expose capability \(params.capability)",
                retryable: false,
                domain: "computer"
            )
        }
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
            return try legacyBrowserCompatibility.execute(params: params)
        }
        guard legacyBrowserMutationLock.try() else {
            throw PluginError(
                code: "BROWSER_AUTOMATION_SERIALIZATION_BUSY",
                message: "Another browser mutation is still in progress; retry instead of waiting inside the Unix-socket request.",
                retryable: true,
                domain: "browser"
            )
        }
        defer { legacyBrowserMutationLock.unlock() }
        return try legacyBrowserCompatibility.execute(params: params)
    }
}
