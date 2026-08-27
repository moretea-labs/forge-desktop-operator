import AppKit
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
    let broker = BrowserAutomationBroker(runner: { command, args, _ in
        executable = command
        arguments = args
        return BrowserAutomationCommandResult(status: 0, stdout: "false\u{1e}https://example.com\u{1e}Example\u{1e}0\u{1e}0\u{1e}800\u{1e}600")
    }, frontmostBundleIdentifier: { "com.google.Chrome" })
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
    #expect(response.result?["value"]?.stringValue?.hasPrefix("true\u{1e}https://example.com") == true)
}

@Test func browserAutomationBrokerListsTabsThroughDeclaredBrokerAction() throws {
    var script = ""
    let inventory = "false\u{1e}10\u{1f}20\u{1f}true\u{1f}https://example.com\u{1f}Example"
    let broker = BrowserAutomationBroker { _, args, _ in
        script = args.joined(separator: "\n")
        return BrowserAutomationCommandResult(status: 0, stdout: inventory)
    }
    let response = PluginRuntime(browserAutomation: broker).handle(RPCRequest(
        id: "list-tabs",
        method: "macos_browser_automation",
        params: .object([
            "protocolVersion": .number(1),
            "action": .string("list_tabs"),
            "product": .string("chrome")
        ])
    ))
    #expect(response.ok)
    #expect(response.result?["value"]?.stringValue == inventory)
    #expect(script.contains("repeat with candidateWindow in windows"))
    #expect(script.contains("id of candidateTab"))
}

@Test func browserAutomationBrokerTrustedInputRequiresExactForegroundTarget() throws {
    var performedKind: String?
    let metadata = "false\u{1e}https://example.com\u{1e}\u{1e}0\u{1e}0\u{1e}800\u{1e}600\u{1e}\u{1e}\u{1e}true\u{1e}false"
    let broker = BrowserAutomationBroker(
        runner: { _, _, _ in BrowserAutomationCommandResult(status: 0, stdout: metadata) },
        frontmostBundleIdentifier: { "com.google.Chrome" },
        trustedInputRunner: { input in performedKind = input["kind"]?.stringValue }
    )
    let response = PluginRuntime(browserAutomation: broker).handle(RPCRequest(
        id: "trusted-input",
        method: "macos_browser_automation",
        params: .object([
            "protocolVersion": .number(1),
            "action": .string("trusted_input"),
            "product": .string("chrome"),
            "ref": .object(["windowId": .string("10"), "tabId": .string("20")]),
            "input": .object(["kind": .string("key"), "key": .string("return")])
        ])
    ))
    #expect(response.ok)
    #expect(response.result?["performed"]?.boolValue == true)
    #expect(performedKind == "key")
}

@Test func browserAutomationBrokerTrustedInputRejectsBackgroundTargetBeforeInput() throws {
    var performed = false
    let metadata = "false\u{1e}https://example.com\u{1e}\u{1e}0\u{1e}0\u{1e}800\u{1e}600\u{1e}\u{1e}\u{1e}false\u{1e}false"
    let broker = BrowserAutomationBroker(
        runner: { _, _, _ in BrowserAutomationCommandResult(status: 0, stdout: metadata) },
        frontmostBundleIdentifier: { "com.google.Chrome" },
        trustedInputRunner: { _ in performed = true }
    )
    let response = PluginRuntime(browserAutomation: broker).handle(RPCRequest(
        id: "trusted-input-background",
        method: "macos_browser_automation",
        params: .object([
            "protocolVersion": .number(1),
            "action": .string("trusted_input"),
            "product": .string("chrome"),
            "ref": .object(["windowId": .string("10"), "tabId": .string("20")]),
            "input": .object(["kind": .string("text"), "text": .string("unsafe")])
        ])
    ))
    #expect(!response.ok)
    #expect(response.error?.code == "BROWSER_AUTOMATION_TRUSTED_INPUT_TARGET_NOT_FOREGROUND")
    #expect(!performed)
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

@Test func browserAutomationBrokerTargetMetadataAvoidsBackgroundTitleCoercion() throws {
    var script = ""
    let broker = BrowserAutomationBroker { _, args, _ in
        script = args.joined(separator: "\n")
        return BrowserAutomationCommandResult(status: 0, stdout: "false\u{1e}https://example.com\u{1e}\u{1e}0\u{1e}0\u{1e}800\u{1e}600\u{1e}\u{1e}\u{1e}false\u{1e}false")
    }
    let response = PluginRuntime(browserAutomation: broker).handle(RPCRequest(
        id: "target-metadata",
        method: "macos_browser_automation",
        params: .object([
            "protocolVersion": .number(1),
            "action": .string("metadata"),
            "product": .string("chrome"),
            "ref": .object(["windowId": .string("10"), "tabId": .string("20")])
        ])
    ))
    #expect(response.ok)
    #expect(script.contains("URL of targetTab as text"))
    #expect(!script.contains("title of targetTab as text"))
}


@Test func browserAutomationBrokerRejectsTargetedBackgroundNavigate() throws {
    let broker = BrowserAutomationBroker { _, _, _ in
        BrowserAutomationCommandResult(status: 0, stdout: "")
    }
    let response = PluginRuntime(browserAutomation: broker).handle(RPCRequest(
        id: "targeted-navigate",
        method: "macos_browser_automation",
        params: .object([
            "protocolVersion": .number(1),
            "action": .string("navigate"),
            "product": .string("chrome"),
            "url": .string("https://example.com/next"),
            "ref": .object(["windowId": .string("10"), "tabId": .string("20")])
        ])
    ))
    #expect(!response.ok)
    #expect(response.error?.code == "BROWSER_AUTOMATION_BACKGROUND_NAVIGATION_REQUIRES_REPLACEMENT")
}

@Test func browserAutomationBrokerCreatesBackgroundTabWithoutActivatingIt() throws {
    var script = ""
    let broker = BrowserAutomationBroker { _, args, _ in
        script = args.joined(separator: "\n")
        return BrowserAutomationCommandResult(status: 0, stdout: "10\u{1e}20")
    }
    let response = PluginRuntime(browserAutomation: broker).handle(RPCRequest(
        id: "background-tab",
        method: "macos_browser_automation",
        params: .object([
            "protocolVersion": .number(1),
            "action": .string("create_tab"),
            "product": .string("chrome"),
            "url": .string("https://example.com")
        ])
    ))
    #expect(response.ok)
    #expect(script.contains("set originalActiveIndex to active tab index of targetWindow"))
    #expect(script.contains("set active tab index of targetWindow to originalActiveIndex"))
    #expect(!script.contains("activate"))
}

@Test func liveBrowserAutomationStaysInBackgroundWhenExplicitlyEnabled() throws {
    guard ProcessInfo.processInfo.environment["FORGE_DESKTOP_LIVE_BROWSER_E2E"] == "1" else { return }
    let broker = BrowserAutomationBroker()
    let separator = Character(String(UnicodeScalar(30)!))
    func value(_ action: String, extra: [String: JSONValue] = [:]) throws -> String {
        var params: [String: JSONValue] = [
            "protocolVersion": .number(1), "action": .string(action), "product": .string("chrome"), "timeoutMs": .number(5_000)
        ]
        extra.forEach { params[$0.key] = $0.value }
        let started = Date()
        do { return try broker.execute(params: .object(params))["value"]?.stringValue ?? "" }
        catch { throw NSError(domain: "forge.desktop.live-browser-e2e", code: 1, userInfo: [NSLocalizedDescriptionKey: "action \(action) failed after \(String(format: "%.2f", Date().timeIntervalSince(started)))s: \(error)"]) }
    }
    func create(_ url: String) throws -> JSONValue {
        let parts = try value("create_tab", extra: ["url": .string(url)]).split(separator: separator, omittingEmptySubsequences: false).map(String.init)
        #expect(parts.count == 2)
        return .object(["windowId": .string(parts[0]), "tabId": .string(parts[1])])
    }
    let before = try value("metadata").split(separator: separator, omittingEmptySubsequences: false).map(String.init)
    let originalURL = before[1]
    let originalFrontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let oldRef = try create("about:blank")
    var currentRef = oldRef
    defer { _ = try? value("close_tab", extra: ["ref": currentRef]); _ = try? value("close_tab", extra: ["ref": oldRef]) }
    let target = try value("metadata", extra: ["ref": oldRef]).split(separator: separator, omittingEmptySubsequences: false).map(String.init)
    #expect(target.count >= 10)
    #expect(target[9] == "false")
    #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == originalFrontmostPid)
    #expect(try value("execute_javascript", extra: ["ref": oldRef, "source": .string("document.location.href")]).contains("about:blank"))

    let replacementURL = "data:text/html,%3Ctitle%3EForge%20E2E%3C%2Ftitle%3E%3Cbody%3Eok%3C%2Fbody%3E"
    let replacementRef = try create(replacementURL)
    currentRef = replacementRef
    Thread.sleep(forTimeInterval: 0.7)
    let replacementMetadata = try value("metadata", extra: ["ref": replacementRef]).split(separator: separator, omittingEmptySubsequences: false).map(String.init)
    #expect(replacementMetadata[9] == "false")
    #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == originalFrontmostPid)
    #expect(try value("execute_javascript", extra: ["ref": replacementRef, "source": .string("document.location.href")]).hasPrefix("data:text/html"))
    #expect(try value("execute_javascript", extra: ["ref": replacementRef, "source": .string("document.title")]) == "Forge E2E")
    _ = try value("close_tab", extra: ["ref": oldRef])

    _ = try value("execute_javascript", extra: ["ref": replacementRef, "source": .string("document.title = 'forge-live-e2e-marker'; document.title")])
    _ = try value("reload", extra: ["ref": replacementRef])
    Thread.sleep(forTimeInterval: 0.3)
    #expect(try value("execute_javascript", extra: ["ref": replacementRef, "source": .string("document.title")]) == "Forge E2E")
    _ = try value("close_tab", extra: ["ref": replacementRef])
    let after = try value("metadata").split(separator: separator, omittingEmptySubsequences: false).map(String.init)
    #expect(after[1] == originalURL)
    #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == originalFrontmostPid)
}
