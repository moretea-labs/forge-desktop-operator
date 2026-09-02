import Foundation
import Testing
@testable import DesktopOperatorCore

@Test func jsonValueRoundTrips() throws {
    let value: JSONValue = .object([
        "text": .string("hello"),
        "count": .number(2),
        "enabled": .bool(true),
        "nested": .array([.null, .string("value")])
    ])
    let data = try JSONEncoder.repoHarness.encode(value)
    #expect(try JSONDecoder.repoHarness.decode(JSONValue.self, from: data) == value)
}

@Test func handshakeReturnsVersionedIdentity() throws {
    let runtime = PluginRuntime(socketPath: "/tmp/desktop-operator-test.sock")
    let response = runtime.handle(RPCRequest(id: "one", method: "handshake"))
    #expect(response.ok)
    #expect(response.result?["pluginId"]?.stringValue == "desktop_operator")
    #expect(response.result?["protocolVersion"]?.stringValue == "1.0")
    let computerCapabilities = response.result?["computerCapabilities"]?.arrayValue ?? []
    #expect(Set(computerCapabilities.compactMap { $0["capabilityId"]?.stringValue }) == Set(ComputerProviderProtocol.allCapabilities))
    let browserCapability = computerCapabilities.first { $0["capabilityId"]?.stringValue == ComputerProviderProtocol.browserAutomationCapability }
    #expect(browserCapability?["method"]?.stringValue == ComputerProviderProtocol.executionMethod)
    #expect(browserCapability?["protocolVersion"]?.intValue == ComputerProviderProtocol.protocolVersion)
    #expect(Set(browserCapability?["actions"]?.arrayValue?.compactMap(\.stringValue) ?? []) == Set(BrowserAutomationBroker.supportedActions))
    #expect(response.result?["internalCapabilities"]?.arrayValue?.compactMap(\.stringValue).contains("macos_browser_automation.v1") == true)
    #expect(response.result?["browserAutomationProtocolVersion"]?.intValue == 1)
    #expect(response.result?["browserAutomationActions"]?.arrayValue?.compactMap(\.stringValue).contains("list_tabs") == true)
    #expect(response.result?["browserAutomationActions"]?.arrayValue?.compactMap(\.stringValue).contains("trusted_input") == true)
}

@Test func unknownMethodIsStructuredError() {
    let runtime = PluginRuntime(socketPath: "/tmp/desktop-operator-test.sock")
    let response = runtime.handle(RPCRequest(id: "bad", method: "missing"))
    #expect(!response.ok)
    #expect(response.error?.code == "UNSUPPORTED")
}

@Test func batchIsBoundedAndReportsStepErrors() throws {
    let runtime = PluginRuntime(socketPath: "/tmp/desktop-operator-test.sock")
    let result = try runtime.execute(action: "desktop_batch", arguments: .object([
        "on_error": .string("continue"),
        "steps": .array([
            .object(["action": .string("unknown"), "arguments": .object([:])]),
            .object(["action": .string("desktop_status"), "arguments": .object(["limit": .number(1)])])
        ])
    ]))
    #expect(result["completed"]?.boolValue == true)
    #expect(result["results"]?.arrayValue?.count == 2)
    #expect(result["results"]?.arrayValue?.first?["ok"]?.boolValue == false)
}

@Test func coordinateFallbackRequiresFreshRefAfterActivation() throws {
    let refOnly = ElementSelector(ref: "ax_1_9")
    #expect(throws: PluginError.self) {
        _ = try AccessibilityDriver.coordinateFallbackSelector(refOnly, applicationWasActive: false)
    }

    let semantic = ElementSelector(ref: "ax_1_9", role: "AXButton", title: "Continue")
    let refreshed = try AccessibilityDriver.coordinateFallbackSelector(semantic, applicationWasActive: false)
    #expect(refreshed.ref == nil)
    #expect(refreshed.role == "AXButton")
    #expect(refreshed.title == "Continue")

    let alreadyActive = try AccessibilityDriver.coordinateFallbackSelector(refOnly, applicationWasActive: true)
    #expect(alreadyActive == refOnly)
}

@Test func desktopPressSemanticScrollActionsAreOnePageAccessibilityActions() throws {
    let press = try AccessibilityDriver.semanticAccessibilityAction("press")
    #expect(press.action as String == "AXPress")
    #expect(press.method == "AXPress_background")
    #expect(!press.isScroll)

    let down = try AccessibilityDriver.semanticAccessibilityAction("scroll_down_page")
    #expect(down.action as String == "AXScrollDownByPage")
    #expect(down.method == "AXScrollDownByPage_background")
    #expect(down.isScroll)

    let up = try AccessibilityDriver.semanticAccessibilityAction("scroll_up_page")
    #expect(up.action as String == "AXScrollUpByPage")
    #expect(up.method == "AXScrollUpByPage_background")
    #expect(up.isScroll)

    #expect(throws: PluginError.self) {
        _ = try AccessibilityDriver.semanticAccessibilityAction("scroll_raw_delta")
    }
}

@Test func forcedCoordinatePressUsesBoundedElementCenter() throws {
    let point = try AccessibilityDriver.coordinateClickPoint(
        frame: DesktopFrame(x: 100, y: 200, width: 40, height: 20),
        displayBounds: [DesktopFrame(x: 0, y: 0, width: 1440, height: 900)]
    )
    #expect(point.x == 120)
    #expect(point.y == 210)
}

@Test func forcedCoordinatePressRejectsInvalidOrOffscreenFrames() {
    #expect(throws: PluginError.self) {
        _ = try AccessibilityDriver.coordinateClickPoint(
            frame: DesktopFrame(x: 100, y: 200, width: 0, height: 20),
            displayBounds: [DesktopFrame(x: 0, y: 0, width: 1440, height: 900)]
        )
    }
    #expect(throws: PluginError.self) {
        _ = try AccessibilityDriver.coordinateClickPoint(
            frame: DesktopFrame(x: 2000, y: 2000, width: 20, height: 20),
            displayBounds: [DesktopFrame(x: 0, y: 0, width: 1440, height: 900)]
        )
    }
}
@Test func applicationDriverDetectsLockedConsoleSessionDictionary() {
    let locked = ["CGSSessionScreenIsLocked": true] as CFDictionary
    let unlocked = ["CGSSessionScreenIsLocked": false] as CFDictionary
    let unrelated = ["kCGSessionLoginDoneKey": true] as CFDictionary
    #expect(ApplicationDriver.sessionIsLocked(locked))
    #expect(!ApplicationDriver.sessionIsLocked(unlocked))
    #expect(!ApplicationDriver.sessionIsLocked(unrelated))
    #expect(!ApplicationDriver.sessionIsLocked(nil))
}

@Test func applicationDriverRejectsDeadPids() {
    #expect(ApplicationDriver.processIsAlive(ProcessInfo.processInfo.processIdentifier))
    #expect(!ApplicationDriver.processIsAlive(Int32.max))
}

@Test func launchServicesFrontmostPIDParsingIsExactAndFailClosed() {
    #expect(ApplicationDriver.parseLaunchServicesFrontmostPID("pid = 25268 !cgsConnection") == 25268)
    #expect(ApplicationDriver.parseLaunchServicesFrontmostPID("pid = nope") == nil)
    #expect(ApplicationDriver.parseLaunchServicesFrontmostPID("bundleID=\"com.google.Chrome\"") == nil)
}

@Test func foregroundIdentityUsesOneAuthoritativeFrontmostPID() {
    #expect(ApplicationDriver.foregroundMatches(pid: 42, frontmostPID: 42))
    #expect(!ApplicationDriver.foregroundMatches(pid: 42, frontmostPID: 43))
    #expect(!ApplicationDriver.foregroundMatches(pid: 42, frontmostPID: nil))
}

@Test func applicationActivationUsesWorkspaceBeforeAccessibilityWhenAppKitDoesNotEstablishForeground() throws {
    var appKitCalls = 0
    var workspaceCalls = 0
    var accessibilityCalls = 0
    var waitCalls = 0
    try ApplicationDriver.establishForegroundAuthority(
        pid: 42,
        timeoutSeconds: 2,
        appKitActivate: {
            appKitCalls += 1
            return true
        },
        workspaceActivate: {
            workspaceCalls += 1
            return true
        },
        accessibilityTrusted: { true },
        accessibilityActivate: {
            accessibilityCalls += 1
            return .success
        },
        waitForFrontmost: { _ in
            waitCalls += 1
            return waitCalls >= 3
        }
    )
    #expect(appKitCalls == 1)
    #expect(workspaceCalls == 1)
    #expect(accessibilityCalls == 0)
    #expect(waitCalls == 3)
}

@Test func applicationActivationFallsBackToAccessibilityWhenWorkspaceStillDoesNotEstablishForeground() throws {
    var workspaceCalls = 0
    var accessibilityCalls = 0
    var waitCalls = 0
    try ApplicationDriver.establishForegroundAuthority(
        pid: 42,
        timeoutSeconds: 2,
        appKitActivate: { true },
        workspaceActivate: {
            workspaceCalls += 1
            return true
        },
        accessibilityTrusted: { true },
        accessibilityActivate: {
            accessibilityCalls += 1
            return .success
        },
        waitForFrontmost: { _ in
            waitCalls += 1
            return waitCalls >= 4
        }
    )
    #expect(workspaceCalls == 1)
    #expect(accessibilityCalls == 1)
    #expect(waitCalls == 4)
}

@Test func applicationActivationDoesNotUseFallbacksWhenAppKitEstablishesForeground() throws {
    var appKitCalls = 0
    var workspaceCalls = 0
    var accessibilityCalls = 0
    var waitCalls = 0
    try ApplicationDriver.establishForegroundAuthority(
        pid: 42,
        timeoutSeconds: 2,
        appKitActivate: {
            appKitCalls += 1
            return true
        },
        workspaceActivate: {
            workspaceCalls += 1
            return true
        },
        accessibilityTrusted: { true },
        accessibilityActivate: {
            accessibilityCalls += 1
            return .success
        },
        waitForFrontmost: { _ in
            waitCalls += 1
            return waitCalls >= 2
        }
    )
    #expect(appKitCalls == 1)
    #expect(workspaceCalls == 0)
    #expect(accessibilityCalls == 0)
    #expect(waitCalls == 2)
}


private func pointerTestWindow(frame: DesktopFrame, onScreen: Bool = true) -> DesktopWindow {
    DesktopWindow(windowId: 77, pid: 42, ownerName: "Test", title: "Window", layer: 0, alpha: 1, onScreen: onScreen, frame: frame)
}

@Test func pointerClickAcceptsFreshMatchingWindowEvidence() throws {
    let capturedAt = Date()
    let frame = DesktopFrame(x: 100, y: 200, width: 400, height: 300)
    let evidence = DesktopVisualEvidence(revision: 3, windowId: 77, frame: frame, capturedAt: capturedAt)
    let validated = try PluginRuntime.validatePointerClickEvidence(
        evidence: evidence,
        requestedRevision: 3,
        requestedWindowId: 77,
        x: 250,
        y: 350,
        currentWindow: pointerTestWindow(frame: frame),
        now: capturedAt.addingTimeInterval(1)
    )
    #expect(validated == frame)
}

@Test func pointerClickRejectsStaleVisualRevisionBeforeInput() {
    let capturedAt = Date()
    let frame = DesktopFrame(x: 100, y: 200, width: 400, height: 300)
    let evidence = DesktopVisualEvidence(revision: 3, windowId: 77, frame: frame, capturedAt: capturedAt)
    do {
        _ = try PluginRuntime.validatePointerClickEvidence(
            evidence: evidence,
            requestedRevision: 2,
            requestedWindowId: 77,
            x: 250,
            y: 350,
            currentWindow: pointerTestWindow(frame: frame),
            now: capturedAt.addingTimeInterval(1)
        )
        Issue.record("Expected stale visual revision rejection")
    } catch let error as PluginError {
        #expect(error.code == "POINTER_CLICK_STALE_VISUAL_REVISION")
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func pointerClickRejectsOutsideOrChangedWindowBeforeInput() {
    let capturedAt = Date()
    let frame = DesktopFrame(x: 100, y: 200, width: 400, height: 300)
    let evidence = DesktopVisualEvidence(revision: 4, windowId: 77, frame: frame, capturedAt: capturedAt)
    do {
        _ = try PluginRuntime.validatePointerClickEvidence(
            evidence: evidence,
            requestedRevision: 4,
            requestedWindowId: 77,
            x: 99,
            y: 350,
            currentWindow: pointerTestWindow(frame: frame),
            now: capturedAt.addingTimeInterval(1)
        )
        Issue.record("Expected outside-window rejection")
    } catch let error as PluginError {
        #expect(error.code == "POINTER_CLICK_OUTSIDE_WINDOW")
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    let moved = DesktopFrame(x: 110, y: 200, width: 400, height: 300)
    do {
        _ = try PluginRuntime.validatePointerClickEvidence(
            evidence: evidence,
            requestedRevision: 4,
            requestedWindowId: 77,
            x: 250,
            y: 350,
            currentWindow: pointerTestWindow(frame: moved),
            now: capturedAt.addingTimeInterval(1)
        )
        Issue.record("Expected moved-window rejection")
    } catch let error as PluginError {
        #expect(error.code == "POINTER_CLICK_WINDOW_CHANGED")
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func pointerClickRejectsExpiredVisualEvidence() {
    let capturedAt = Date()
    let frame = DesktopFrame(x: 100, y: 200, width: 400, height: 300)
    let evidence = DesktopVisualEvidence(revision: 5, windowId: 77, frame: frame, capturedAt: capturedAt)
    do {
        _ = try PluginRuntime.validatePointerClickEvidence(
            evidence: evidence,
            requestedRevision: 5,
            requestedWindowId: 77,
            x: 250,
            y: 350,
            currentWindow: pointerTestWindow(frame: frame),
            now: capturedAt.addingTimeInterval(16)
        )
        Issue.record("Expected expired-evidence rejection")
    } catch let error as PluginError {
        #expect(error.code == "POINTER_CLICK_STALE_VISUAL_REVISION")
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
