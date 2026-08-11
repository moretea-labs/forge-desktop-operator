import Foundation
import Testing
@testable import DesktopOperatorCore

@Test func browserAutomationBrokerOnlyAcceptsBoundedProducts() throws {
    var calls = 0
    let broker = BrowserAutomationBroker { _, _, _ in
        calls += 1
        return BrowserAutomationCommandResult(status: 0, stdout: "ok")
    }
    let response = PluginRuntime(browserAutomation: broker).handle(RPCRequest(
        id: "bad-product",
        method: "macos_browser_automation",
        params: .object([
            "protocolVersion": .number(1),
            "action": .string("metadata"),
            "product": .string("Safari")
        ])
    ))
    #expect(!response.ok)
    #expect(response.error?.code == "BROWSER_AUTOMATION_PRODUCT_INVALID")
    #expect(calls == 0)
}

@Test func browserAutomationBrokerDoesNotExposeArbitraryAppleScript() throws {
    var calls = 0
    let broker = BrowserAutomationBroker { _, _, _ in
        calls += 1
        return BrowserAutomationCommandResult(status: 0)
    }
    let response = PluginRuntime(browserAutomation: broker).handle(RPCRequest(
        id: "raw-script",
        method: "macos_browser_automation",
        params: .object([
            "protocolVersion": .number(1),
            "action": .string("run_applescript"),
            "product": .string("chrome"),
            "script": .string("tell application \"Finder\" to quit")
        ])
    ))
    #expect(!response.ok)
    #expect(response.error?.code == "BROWSER_AUTOMATION_ACTION_UNSUPPORTED")
    #expect(calls == 0)
}

@Test func browserAutomationBrokerRunsChromeMetadataThroughStableProcess() throws {
    var executable = ""
    var arguments: [String] = []
    let broker = BrowserAutomationBroker { command, args, _ in
        executable = command
        arguments = args
        return BrowserAutomationCommandResult(status: 0, stdout: "false\u{1e}https://example.com\u{1e}Example\u{1e}0\u{1e}0\u{1e}800\u{1e}600")
    }
    let response = PluginRuntime(browserAutomation: broker).handle(RPCRequest(
        id: "metadata",
        method: "macos_browser_automation",
        params: .object([
            "protocolVersion": .number(1),
            "action": .string("metadata"),
            "product": .string("chrome"),
            "timeoutMs": .number(1_000)
        ])
    ))
    #expect(response.ok)
    #expect(executable == "/usr/bin/osascript")
    #expect(arguments.first == "-e")
    #expect(arguments.joined(separator: " ").contains("Google Chrome"))
    #expect(response.result?["value"]?.stringValue?.contains("https://example.com") == true)
}

@Test func browserAutomationBrokerIsInternalNotPublicPluginAction() throws {
    #expect(!PluginManifest.current.actions.contains("macos_browser_automation"))
    let runtime = PluginRuntime()
    do {
        _ = try runtime.execute(action: "macos_browser_automation", arguments: .object([:]))
        Issue.record("expected public execute surface to reject internal broker RPC")
    } catch let error as PluginError {
        #expect(error.code == "UNSUPPORTED")
    }
}
