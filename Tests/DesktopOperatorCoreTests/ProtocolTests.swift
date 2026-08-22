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
@Test func applicationDriverRejectsDeadPids() {
    #expect(ApplicationDriver.processIsAlive(ProcessInfo.processInfo.processIdentifier))
    #expect(!ApplicationDriver.processIsAlive(Int32.max))
}

@Test func foregroundIdentityUsesOneAuthoritativeFrontmostPID() {
    #expect(ApplicationDriver.foregroundMatches(pid: 42, frontmostPID: 42))
    #expect(!ApplicationDriver.foregroundMatches(pid: 42, frontmostPID: 43))
    #expect(!ApplicationDriver.foregroundMatches(pid: 42, frontmostPID: nil))
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
