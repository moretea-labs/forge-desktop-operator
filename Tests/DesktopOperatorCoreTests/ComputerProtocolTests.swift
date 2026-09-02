import Foundation
import Testing
@testable import DesktopOperatorCore

@Test func computerExecuteRoutesBrowserAutomationThroughProviderNeutralCapability() throws {
    var calls = 0
    let broker = BrowserAutomationBroker { _, _, _ in
        calls += 1
        return BrowserAutomationCommandResult(status: 0, stdout: "false\u{1e}https://example.com\u{1e}Example\u{1e}0\u{1e}0\u{1e}800\u{1e}600")
    }
    let runtime = PluginRuntime(browserAutomation: broker)
    let response = runtime.handle(RPCRequest(
        id: "computer-browser-metadata",
        method: ComputerProviderProtocol.executionMethod,
        params: try JSONValue.encode(ComputerExecuteParams(
            capability: ComputerProviderProtocol.browserAutomationCapability,
            protocolVersion: ComputerProviderProtocol.protocolVersion,
            arguments: .object([
                "action": .string("metadata"),
                "product": .string("chrome"),
                "timeoutMs": .number(1_000),
            ])
        ))
    ))

    #expect(response.ok)
    #expect(calls == 1)
}

@Test func computerExecuteRejectsUnknownCapabilityBeforeNativeDispatch() throws {
    var calls = 0
    let broker = BrowserAutomationBroker { _, _, _ in
        calls += 1
        return BrowserAutomationCommandResult(status: 0, stdout: "ok")
    }
    let response = PluginRuntime(browserAutomation: broker).handle(RPCRequest(
        id: "computer-unknown-capability",
        method: ComputerProviderProtocol.executionMethod,
        params: try JSONValue.encode(ComputerExecuteParams(
            capability: "computer.arbitrary_shell.v1",
            protocolVersion: ComputerProviderProtocol.protocolVersion,
            arguments: .object(["action": .string("run")])
        ))
    ))

    #expect(!response.ok)
    #expect(response.error?.code == "COMPUTER_CAPABILITY_UNSUPPORTED")
    #expect(calls == 0)
}

@Test func computerExecuteRejectsUnsupportedProtocolVersionBeforeNativeDispatch() throws {
    var calls = 0
    let broker = BrowserAutomationBroker { _, _, _ in
        calls += 1
        return BrowserAutomationCommandResult(status: 0, stdout: "ok")
    }
    let response = PluginRuntime(browserAutomation: broker).handle(RPCRequest(
        id: "computer-version-mismatch",
        method: ComputerProviderProtocol.executionMethod,
        params: try JSONValue.encode(ComputerExecuteParams(
            capability: ComputerProviderProtocol.browserAutomationCapability,
            protocolVersion: 999,
            arguments: .object(["action": .string("metadata"), "product": .string("chrome")])
        ))
    ))

    #expect(!response.ok)
    #expect(response.error?.code == "COMPUTER_PROTOCOL_VERSION_UNSUPPORTED")
    #expect(calls == 0)
}

@Test func legacyBrowserAutomationRemainsACompatibilityAlias() throws {
    var calls = 0
    let broker = BrowserAutomationBroker { _, _, _ in
        calls += 1
        return BrowserAutomationCommandResult(status: 0, stdout: "false\u{1e}https://example.com\u{1e}Example\u{1e}0\u{1e}0\u{1e}800\u{1e}600")
    }
    let response = PluginRuntime(browserAutomation: broker).handle(RPCRequest(
        id: "legacy-browser-metadata",
        method: "macos_browser_automation",
        params: .object([
            "protocolVersion": .number(1),
            "action": .string("metadata"),
            "product": .string("chrome"),
            "timeoutMs": .number(1_000),
        ])
    ))

    #expect(response.ok)
    #expect(calls == 1)
}
