import Foundation
import ApplicationServices
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

@Test func computerExecuteRoutesUnifiedElementV2CapabilitiesWithoutBrowserOrNativeFallback() throws {
    var browserCalls = 0
    var nativeCalls = 0
    var observeCalls = 0
    var actionCalls = 0
    let runtime = ComputerProviderRuntime(browserAutomation: BrowserAutomationBroker { _, _, _ in
        browserCalls += 1
        return BrowserAutomationCommandResult(status: 0, stdout: "ok")
    })

    let observe = try runtime.execute(
        ComputerExecuteParams(
            capability: ComputerProviderProtocol.elementObserveCapability,
            protocolVersion: ComputerProviderProtocol.elementProtocolVersion,
            arguments: .object(["interactionId": .string("desk_test")])
        ),
        nativeAction: { _, _ in nativeCalls += 1; return .string("native") },
        elementObserve: { _ in observeCalls += 1; return .string("observed") },
        elementAction: { _ in actionCalls += 1; return .string("acted") }
    )
    #expect(observe.stringValue == "observed")
    #expect(observeCalls == 1)
    #expect(actionCalls == 0)
    #expect(nativeCalls == 0)
    #expect(browserCalls == 0)

    let action = try runtime.execute(
        ComputerExecuteParams(
            capability: ComputerProviderProtocol.elementActionCapability,
            protocolVersion: ComputerProviderProtocol.elementProtocolVersion,
            arguments: .object(["action": .string("invoke")])
        ),
        nativeAction: { _, _ in nativeCalls += 1; return .string("native") },
        elementObserve: { _ in observeCalls += 1; return .string("observed") },
        elementAction: { _ in actionCalls += 1; return .string("acted") }
    )
    #expect(action.stringValue == "acted")
    #expect(actionCalls == 1)
    #expect(nativeCalls == 0)
    #expect(browserCalls == 0)
}

@Test func computerExecuteRoutesLegacyNativeCapabilityThroughTypedActionFence() throws {
    var routedAction: String?
    var routedArguments: JSONValue?
    let runtime = ComputerProviderRuntime(browserAutomation: BrowserAutomationBroker { _, _, _ in
        BrowserAutomationCommandResult(status: 0, stdout: "ok")
    })

    let result = try runtime.execute(
        ComputerExecuteParams(
            capability: ComputerProviderProtocol.inputCapability,
            protocolVersion: ComputerProviderProtocol.legacyProtocolVersion,
            arguments: .object([
                "action": .string("desktop_key"),
                "keys": .array([.string("escape")]),
            ])
        ),
        nativeAction: { action, arguments in
            routedAction = action
            routedArguments = arguments
            return .string("native")
        },
        elementObserve: { _ in Issue.record("Unexpected element observe route"); return .null },
        elementAction: { _ in Issue.record("Unexpected element action route"); return .null }
    )

    #expect(result.stringValue == "native")
    #expect(routedAction == "desktop_key")
    #expect(routedArguments?["action"] == nil)
    #expect(routedArguments?["keys"]?.arrayValue?.count == 1)
}

@Test func computerElementV2RejectsUnknownSemanticActionBeforeProviderDispatch() throws {
    var elementActionCalls = 0
    let runtime = ComputerProviderRuntime(browserAutomation: BrowserAutomationBroker { _, _, _ in
        BrowserAutomationCommandResult(status: 0, stdout: "ok")
    })

    do {
        _ = try runtime.execute(
            ComputerExecuteParams(
                capability: ComputerProviderProtocol.elementActionCapability,
                protocolVersion: ComputerProviderProtocol.elementProtocolVersion,
                arguments: .object(["action": .string("raw_coordinate_click")])
            ),
            nativeAction: { _, _ in .null },
            elementObserve: { _ in .null },
            elementAction: { _ in elementActionCalls += 1; return .null }
        )
        Issue.record("Expected semantic action fence rejection")
    } catch let error as PluginError {
        #expect(error.code == "COMPUTER_ACTION_UNSUPPORTED")
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    #expect(elementActionCalls == 0)
}

@Test func normalizedComputerElementCarriesExactWindowContextAndObservedBoundsOnly() {
    let frame = DesktopFrame(x: 10, y: 20, width: 300, height: 200)
    let child = AXNode(
        ref: "ax_4_2", role: "AXButton", subrole: nil, title: "Save", identifier: "save",
        description: nil, value: nil, enabled: true, focused: false, selected: nil, expanded: nil,
        frame: frame, actions: ["AXPress"], children: []
    )
    let window = AXNode(
        ref: "ax_4_1", role: "AXWindow", subrole: nil, title: "Editor", identifier: nil,
        description: nil, value: nil, enabled: true, focused: true, selected: nil, expanded: nil,
        frame: DesktopFrame(x: 0, y: 0, width: 800, height: 600), actions: [], children: [child]
    )
    let record = DesktopSessionRecord(
        interactionId: "desk_exact", pid: 123, bundleIdentifier: "com.example.editor",
        appName: "Editor", createdAt: Date(), lastObservedAt: Date(), snapshotRevision: 4
    )

    let normalized = AccessibilityDriver.normalizeElement(
        window, record: record, snapshotRevision: 4, inheritedWindowRef: nil
    )
    let button = normalized.children[0]
    #expect(button.target.interactionId == "desk_exact")
    #expect(button.target.pid == 123)
    #expect(button.target.bundleIdentifier == "com.example.editor")
    #expect(button.target.windowRef == "ax_4_1")
    #expect(button.target.snapshotRevision == 4)
    #expect(button.ref == "ax_4_2")
    #expect(button.bounds == frame)
    #expect(button.actions.contains("invoke"))
}

@Test func computerElementTargetIdentityRejectsCrossSessionAndWindowRefReuse() throws {
    let record = DesktopSessionRecord(
        interactionId: "desk_exact", pid: 123, bundleIdentifier: "com.example.editor",
        appName: "Editor", createdAt: Date(), lastObservedAt: Date(), snapshotRevision: 4
    )
    let session = DesktopSessionState(record: record)
    let element = AXUIElementCreateSystemWide()
    session.elements["ax_4_1"] = element
    session.elements["ax_4_2"] = element
    session.elementWindowRefs["ax_4_2"] = "ax_4_1"

    let exact = ComputerElementTarget(
        interactionId: "desk_exact", pid: 123, bundleIdentifier: "com.example.editor",
        appName: "Editor", windowRef: "ax_4_1", snapshotRevision: 4
    )
    try AccessibilityDriver.validateObservedTargetIdentity(session: session, ref: "ax_4_2", target: exact)

    let wrongSession = ComputerElementTarget(
        interactionId: "desk_other", pid: 123, bundleIdentifier: "com.example.editor",
        appName: "Editor", windowRef: "ax_4_1", snapshotRevision: 4
    )
    do {
        try AccessibilityDriver.validateObservedTargetIdentity(session: session, ref: "ax_4_2", target: wrongSession)
        Issue.record("Expected cross-session target rejection")
    } catch let error as PluginError {
        #expect(error.code == "COMPUTER_ELEMENT_TARGET_MISMATCH")
    }

    let wrongWindow = ComputerElementTarget(
        interactionId: "desk_exact", pid: 123, bundleIdentifier: "com.example.editor",
        appName: "Editor", windowRef: "ax_4_9", snapshotRevision: 4
    )
    do {
        try AccessibilityDriver.validateObservedTargetIdentity(session: session, ref: "ax_4_2", target: wrongWindow)
        Issue.record("Expected cross-window target rejection")
    } catch let error as PluginError {
        #expect(error.code == "COMPUTER_ELEMENT_TARGET_MISMATCH")
    }
}
