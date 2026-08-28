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

@Test func browserAutomationBrokerCreatesBackgroundTabWithStableAssignmentProvenance() throws {
    var script = ""
    let separator = String(UnicodeScalar(30)!)
    let requestedURL = "https://example.com/requested"
    let observedURL = "https://example.com/canonical"
    let broker = BrowserAutomationBroker { _, args, _ in
        script = args.joined(separator: "\n")
        return BrowserAutomationCommandResult(status: 0, stdout: ["10", "20", requestedURL, observedURL].joined(separator: separator))
    }
    let response = PluginRuntime(browserAutomation: broker).handle(RPCRequest(
        id: "background-tab",
        method: "macos_browser_automation",
        params: .object([
            "protocolVersion": .number(1),
            "action": .string("create_tab"),
            "product": .string("chrome"),
            "url": .string(requestedURL)
        ])
    ))
    #expect(response.ok)
    #expect(response.result?["value"]?.stringValue == ["10", "20"].joined(separator: separator))
    #expect(response.result?["ref"]?["windowId"]?.stringValue == "10")
    #expect(response.result?["ref"]?["tabId"]?.stringValue == "20")
    #expect(response.result?["navigation"]?["requestedUrl"]?.stringValue == requestedURL)
    #expect(response.result?["navigation"]?["assignmentAccepted"]?.boolValue == true)
    #expect(response.result?["navigation"]?["observedUrlAfterAssignment"]?.stringValue == observedURL)
    #expect(script.contains("set originalActiveTabId to ((id of active tab of targetWindow) as text)"))
    #expect(script.contains("set URL of targetTab to targetUrl"))
    #expect(script.contains("if activeTabIdAfterCreate is (targetTabId as text) then"))
    #expect(script.contains("if ((id of candidateTab) as text) is originalActiveTabId then"))
    #expect(!script.contains("originalActiveIndex"))
    #expect(!script.contains("activate\n"))
}

@Test func browserAutomationBrokerRejectsCreateTabWithoutExactAssignmentProof() throws {
    let broker = BrowserAutomationBroker { _, _, _ in
        BrowserAutomationCommandResult(status: 0, stdout: "10\u{1e}20")
    }
    let response = PluginRuntime(browserAutomation: broker).handle(RPCRequest(
        id: "background-tab-missing-proof",
        method: "macos_browser_automation",
        params: .object([
            "protocolVersion": .number(1),
            "action": .string("create_tab"),
            "product": .string("chrome"),
            "url": .string("https://example.com/requested")
        ])
    ))
    #expect(!response.ok)
    #expect(response.error?.code == "BROWSER_AUTOMATION_CREATE_TAB_PROVENANCE_INVALID")
}

@Test func browserAutomationBrokerTrustedInputFailsClosedUnlessExactTargetIsForeground() throws {
    var performed = 0
    var scripts: [String] = []
    let broker = BrowserAutomationBroker(
        runner: { _, args, _ in
            scripts.append(args.joined(separator: "\n"))
            return BrowserAutomationCommandResult(status: 0, stdout: "false\u{1e}https://example.com\u{1e}\u{1e}0\u{1e}0\u{1e}1000\u{1e}800\u{1e}10\u{1e}20\u{1e}true\u{1e}false")
        },
        frontmostBundleIdentifier: { "com.example.Other" },
        trustedInputPerformer: { _ in performed += 1 }
    )
    let response = PluginRuntime(browserAutomation: broker).handle(RPCRequest(
        id: "trusted-input-background",
        method: "macos_browser_automation",
        params: .object([
            "protocolVersion": .number(1),
            "action": .string("trusted_input"),
            "product": .string("chrome"),
            "ref": .object(["windowId": .string("10"), "tabId": .string("20")]),
            "input": .object(["kind": .string("key"), "key": .string("ArrowLeft")])
        ])
    ))
    #expect(!response.ok)
    #expect(response.error?.code == "BROWSER_AUTOMATION_FOREGROUND_REQUIRED")
    #expect(performed == 0)
    #expect(!scripts.joined(separator: "\n").contains("activate\n"))
}

@Test func browserAutomationBrokerTrustedInputTranslatesViewportCoordinatesWithoutActivation() throws {
    var performed: BrowserAutomationTrustedInputCommand?
    var scripts: [String] = []
    let broker = BrowserAutomationBroker(
        runner: { _, args, _ in
            let script = args.joined(separator: "\n")
            scripts.append(script)
            if script.contains("window.screenX") {
                return BrowserAutomationCommandResult(status: 0, stdout: "{\"screenX\":100,\"screenY\":50,\"outerWidth\":1000,\"outerHeight\":800,\"innerWidth\":980,\"innerHeight\":700}")
            }
            return BrowserAutomationCommandResult(status: 0, stdout: "false\u{1e}https://example.com\u{1e}\u{1e}0\u{1e}0\u{1e}1000\u{1e}800\u{1e}10\u{1e}20\u{1e}true\u{1e}false")
        },
        frontmostBundleIdentifier: { "com.google.Chrome" },
        trustedInputPerformer: { performed = $0 }
    )
    let response = PluginRuntime(browserAutomation: broker).handle(RPCRequest(
        id: "trusted-input-click",
        method: "macos_browser_automation",
        params: .object([
            "protocolVersion": .number(1),
            "action": .string("trusted_input"),
            "product": .string("chrome"),
            "ref": .object(["windowId": .string("10"), "tabId": .string("20")]),
            "input": .object([
                "kind": .string("click"), "x": .number(20), "y": .number(30),
                "button": .string("right"), "clickCount": .number(2)
            ])
        ])
    ))
    #expect(response.ok)
    #expect(response.result?["performed"]?.boolValue == true)
    #expect(performed?.kind == "click")
    #expect(performed?.x == 130)
    #expect(performed?.y == 180)
    #expect(performed?.button == "right")
    #expect(performed?.clickCount == 2)
    #expect(!scripts.joined(separator: "\n").contains("activate\n"))
}

@Test func browserAutomationBrokerDeclaresTrustedInput() {
    #expect(BrowserAutomationBroker.supportedActions.contains("trusted_input"))
}

private final class BrowserRuntimeBox: @unchecked Sendable {
    let runtime: PluginRuntime
    init(_ runtime: PluginRuntime) { self.runtime = runtime }
}

@Test func browserReadProbesBypassBusyMutationAndCompetingMutationFailsFast() throws {
    let createStarted = DispatchSemaphore(value: 0)
    let releaseCreate = DispatchSemaphore(value: 0)
    let createFinished = DispatchSemaphore(value: 0)
    let separator = String(UnicodeScalar(30)!)
    let broker = BrowserAutomationBroker { _, args, _ in
        let script = args.joined(separator: "\n")
        if script.contains("make new tab") {
            let requestedURL = args.last ?? ""
            createStarted.signal()
            _ = releaseCreate.wait(timeout: .now() + 2)
            return BrowserAutomationCommandResult(status: 0, stdout: ["10", UUID().uuidString, requestedURL, requestedURL].joined(separator: separator))
        }
        return BrowserAutomationCommandResult(status: 0, stdout: "false\u{1e}https://example.com\u{1e}Example\u{1e}0\u{1e}0\u{1e}800\u{1e}600")
    }
    let box = BrowserRuntimeBox(PluginRuntime(browserAutomation: broker))
    DispatchQueue.global().async {
        _ = box.runtime.handle(RPCRequest(
            id: "slow-create", method: "macos_browser_automation",
            params: .object(["protocolVersion": .number(1), "action": .string("create_tab"), "product": .string("chrome"), "url": .string("https://slow.example")])
        ))
        createFinished.signal()
    }
    #expect(createStarted.wait(timeout: .now() + 1) == .success)
    let metadata = box.runtime.handle(RPCRequest(
        id: "metadata-while-create", method: "macos_browser_automation",
        params: .object(["protocolVersion": .number(1), "action": .string("metadata"), "product": .string("chrome")])
    ))
    #expect(metadata.ok)
    let competing = box.runtime.handle(RPCRequest(
        id: "competing-create", method: "macos_browser_automation",
        params: .object(["protocolVersion": .number(1), "action": .string("create_tab"), "product": .string("chrome"), "url": .string("https://competing.example")])
    ))
    #expect(!competing.ok)
    #expect(competing.error?.code == "BROWSER_AUTOMATION_SERIALIZATION_BUSY")
    releaseCreate.signal()
    #expect(createFinished.wait(timeout: .now() + 1) == .success)
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
        let response = try broker.execute(params: .object([
            "protocolVersion": .number(1), "action": .string("create_tab"), "product": .string("chrome"),
            "timeoutMs": .number(5_000), "url": .string(url)
        ]))
        let parts = response["value"]?.stringValue?.split(separator: separator, omittingEmptySubsequences: false).map(String.init) ?? []
        #expect(parts.count == 2)
        #expect(response["navigation"]?["requestedUrl"]?.stringValue == url)
        #expect(response["navigation"]?["assignmentAccepted"]?.boolValue == true)
        return response["ref"] ?? .object(["windowId": .string(parts[0]), "tabId": .string(parts[1])])
    }
    let before = try value("metadata").split(separator: separator, omittingEmptySubsequences: false).map(String.init)
    let originalURL = before[1]
    let originalFrontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let exactTuneMyMusicURL = "https://www.tunemymusic.com/transfer/spotify-to-apple-music"
    let tuneMyMusicRef = try create(exactTuneMyMusicURL)
    defer { _ = try? value("close_tab", extra: ["ref": tuneMyMusicRef]) }
    Thread.sleep(forTimeInterval: 0.7)
    let tuneMyMusicMetadata = try value("metadata", extra: ["ref": tuneMyMusicRef]).split(separator: separator, omittingEmptySubsequences: false).map(String.init)
    #expect(tuneMyMusicMetadata.count >= 10)
    #expect(tuneMyMusicMetadata[8] == tuneMyMusicRef.objectValue?["tabId"]?.stringValue)
    #expect(tuneMyMusicMetadata[9] == "false")
    #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == originalFrontmostPid)

    for _ in 0..<3 {
        _ = try value("metadata")
        _ = try value("list_tabs")
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == originalFrontmostPid)
    }

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
