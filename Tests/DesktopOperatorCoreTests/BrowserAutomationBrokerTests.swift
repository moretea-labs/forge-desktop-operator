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


@Test func browserAutomationBrokerNavigatesTargetedBackgroundTabInPlace() throws {
    var script = ""
    var arguments: [String] = []
    let broker = BrowserAutomationBroker { _, args, _ in
        script = args.first(where: { $0.contains("tell application") }) ?? ""
        arguments = args
        return BrowserAutomationCommandResult(status: 0, stdout: "https://example.com/next")
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
    #expect(response.ok)
    #expect(script.contains("set targetTabId to \"20\""))
    #expect(script.contains("repeat with candidateWindow in windows"))
    #expect(script.contains("set URL of targetTab to targetUrl"))
    #expect(!script.contains("activate"))
    #expect(arguments.contains("https://example.com/next"))
}

@Test func browserAutomationBrokerListsCurrentTabsWithoutChangingBrowserState() throws {
    var script = ""
    let recordSeparator = String(UnicodeScalar(30)!)
    let fieldSeparator = String(UnicodeScalar(31)!)
    let payload = [
        "false",
        ["10", "20", "true", "https://appstoreconnect.apple.com/apps/6775778505/distribution", "App Store Connect"].joined(separator: fieldSeparator),
        ["11", "21", "false", "https://example.com", "Example"].joined(separator: fieldSeparator),
    ].joined(separator: recordSeparator)
    let broker = BrowserAutomationBroker { _, args, _ in
        script = args.joined(separator: "\n")
        return BrowserAutomationCommandResult(status: 0, stdout: payload)
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
    #expect(response.result?["value"]?.stringValue == payload)
    #expect(script.contains("repeat with candidateWindow in windows"))
    #expect(script.contains("repeat with candidateTab in tabs of candidateWindow"))
    #expect(script.contains("set maxTabs to 256"))
    #expect(!script.contains("activate\n"))
    #expect(!script.contains("set active tab index"))
    #expect(!script.contains("make new tab"))
    #expect(!script.contains("close candidateTab"))
}

@Test func browserAutomationBrokerRejectsTargetedTabInventory() throws {
    var calls = 0
    let broker = BrowserAutomationBroker { _, _, _ in
        calls += 1
        return BrowserAutomationCommandResult(status: 0, stdout: "false")
    }
    let response = PluginRuntime(browserAutomation: broker).handle(RPCRequest(
        id: "list-tabs-targeted",
        method: "macos_browser_automation",
        params: .object([
            "protocolVersion": .number(1),
            "action": .string("list_tabs"),
            "product": .string("chrome"),
            "ref": .object(["windowId": .string("10"), "tabId": .string("20")])
        ])
    ))
    #expect(!response.ok)
    #expect(response.error?.code == "BROWSER_AUTOMATION_TAB_REF_UNSUPPORTED")
    #expect(calls == 0)
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
    defer { _ = try? value("close_tab", extra: ["ref": oldRef]) }
    let target = try value("metadata", extra: ["ref": oldRef]).split(separator: separator, omittingEmptySubsequences: false).map(String.init)
    #expect(target.count >= 10)
    #expect(target[9] == "false")
    #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == originalFrontmostPid)
    #expect(try value("execute_javascript", extra: ["ref": oldRef, "source": .string("document.location.href")]).contains("about:blank"))

    let navigatedURL = "data:text/html,%3Ctitle%3EForge%20E2E%3C%2Ftitle%3E%3Cbody%3Eok%3C%2Fbody%3E"
    _ = try value("navigate", extra: ["ref": oldRef, "url": .string(navigatedURL)])
    Thread.sleep(forTimeInterval: 0.7)
    let navigatedMetadata = try value("metadata", extra: ["ref": oldRef]).split(separator: separator, omittingEmptySubsequences: false).map(String.init)
    #expect(navigatedMetadata[9] == "false")
    #expect(navigatedMetadata[8] == oldRef.objectValue?["tabId"]?.stringValue)
    #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == originalFrontmostPid)
    #expect(try value("execute_javascript", extra: ["ref": oldRef, "source": .string("document.location.href")]).hasPrefix("data:text/html"))
    #expect(try value("execute_javascript", extra: ["ref": oldRef, "source": .string("document.title")]) == "Forge E2E")

    _ = try value("execute_javascript", extra: ["ref": oldRef, "source": .string("document.title = 'forge-live-e2e-marker'; document.title")])
    _ = try value("reload", extra: ["ref": oldRef])
    Thread.sleep(forTimeInterval: 0.3)
    #expect(try value("execute_javascript", extra: ["ref": oldRef, "source": .string("document.title")]) == "Forge E2E")
    _ = try value("close_tab", extra: ["ref": oldRef])
    let after = try value("metadata").split(separator: separator, omittingEmptySubsequences: false).map(String.init)
    #expect(after[1] == originalURL)
    #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == originalFrontmostPid)
}
