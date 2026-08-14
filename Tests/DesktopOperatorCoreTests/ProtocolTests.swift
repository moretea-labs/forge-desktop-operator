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
