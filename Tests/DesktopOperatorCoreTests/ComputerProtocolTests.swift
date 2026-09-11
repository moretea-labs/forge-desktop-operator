import Foundation
import ApplicationServices
import Testing
@testable import DesktopOperatorCore

@Test func computerExecuteDoesNotAdvertiseOrRouteLegacyBrowserCompatibilityAsUnifiedComputer() throws {
    var calls = 0
    let broker = BrowserAutomationBroker { _, _, _ in
        calls += 1
        return BrowserAutomationCommandResult(status: 0, stdout: "ok")
    }
    let runtime = PluginRuntime(browserAutomation: broker)
    let health = runtime.health()
    #expect(!health.computerCapabilities.contains { $0.capabilityId == ComputerProviderProtocol.browserAutomationCompatibilityCapability })

    let response = runtime.handle(RPCRequest(
        id: "computer-browser-compatibility-not-unified",
        method: ComputerProviderProtocol.executionMethod,
        params: try JSONValue.encode(ComputerExecuteParams(
            capability: ComputerProviderProtocol.browserAutomationCompatibilityCapability,
            protocolVersion: ComputerProviderProtocol.legacyProtocolVersion,
            arguments: .object(["action": .string("metadata")])
        ))
    ))

    #expect(!response.ok)
    #expect(response.error?.code == "COMPUTER_CAPABILITY_UNSUPPORTED")
    #expect(calls == 0)
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
            capability: ComputerProviderProtocol.elementObserveCapability,
            protocolVersion: 999,
            arguments: .object(["interactionId": .string("desk_version_test")])
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

    routedAction = nil
    routedArguments = nil
    let openURL = try runtime.execute(
        ComputerExecuteParams(
            capability: ComputerProviderProtocol.inputCapability,
            protocolVersion: ComputerProviderProtocol.legacyProtocolVersion,
            arguments: .object([
                "action": .string("desktop_open_url"),
                "url": .string("https://example.com")
            ])
        ),
        nativeAction: { action, arguments in
            routedAction = action
            routedArguments = arguments
            return .string("opened")
        },
        elementObserve: { _ in Issue.record("Unexpected element observe route"); return .null },
        elementAction: { _ in Issue.record("Unexpected element action route"); return .null }
    )
    #expect(openURL.stringValue == "opened")
    #expect(routedAction == "desktop_open_url")
    #expect(routedArguments?["action"] == nil)
    #expect(routedArguments?["url"]?.stringValue == "https://example.com")
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

@Test func computerElementBehaviorLoopRequiresFreshReobservationAfterSemanticMutation() throws {
    let runtime = ComputerProviderRuntime(browserAutomation: BrowserAutomationBroker { _, _, _ in
        Issue.record("Legacy browser compatibility must not participate in Computer element behavior")
        return BrowserAutomationCommandResult(status: 1)
    })
    let ax = AXUIElementCreateSystemWide()
    let record = DesktopSessionRecord(
        interactionId: "desk_behavior", pid: 321, bundleIdentifier: "com.example.Editor",
        appName: "Editor", createdAt: Date(), lastObservedAt: Date(), snapshotRevision: 7
    )
    let session = DesktopSessionState(record: record)

    func bindObservation(revision: Int) -> ComputerElementTarget {
        let windowRef = "ax_\(revision)_1"
        let elementRef = "ax_\(revision)_2"
        session.elements[windowRef] = ax
        session.elements[elementRef] = ax
        session.elementWindowRefs[elementRef] = windowRef
        session.record.snapshotRevision = revision
        session.record.lastObservedAt = Date()
        return ComputerElementTarget(
            interactionId: session.record.interactionId,
            pid: session.record.pid,
            bundleIdentifier: session.record.bundleIdentifier,
            appName: session.record.appName,
            windowRef: windowRef,
            snapshotRevision: revision
        )
    }

    let initialTarget = bindObservation(revision: 7)
    var observeCount = 0
    let firstObservation = try runtime.execute(
        ComputerExecuteParams(
            capability: ComputerProviderProtocol.elementObserveCapability,
            protocolVersion: ComputerProviderProtocol.elementProtocolVersion,
            arguments: .object(["interactionId": .string("desk_behavior")])
        ),
        nativeAction: { _, _ in Issue.record("Unexpected native action"); return .null },
        elementObserve: { _ in
            observeCount += 1
            return .object([
                "ref": .string("ax_7_2"),
                "snapshotRevision": .number(7),
                "windowRef": .string("ax_7_1"),
                "actions": .array([.string("invoke")]),
                "boundsAreIdentity": .bool(false),
            ])
        },
        elementAction: { _ in Issue.record("Unexpected element action during observe"); return .null }
    )
    #expect(firstObservation["ref"]?.stringValue == "ax_7_2")
    #expect(firstObservation["windowRef"]?.stringValue == "ax_7_1")
    #expect(firstObservation["actions"]?.arrayValue?.compactMap(\.stringValue) == ["invoke"])
    #expect(firstObservation["boundsAreIdentity"]?.boolValue == false)

    let action = try runtime.execute(
        ComputerExecuteParams(
            capability: ComputerProviderProtocol.elementActionCapability,
            protocolVersion: ComputerProviderProtocol.elementProtocolVersion,
            arguments: try JSONValue.encode(ComputerElementActionParams(
                target: initialTarget, ref: "ax_7_2", action: "invoke"
            ))
        ),
        nativeAction: { _, _ in Issue.record("Unexpected native action"); return .null },
        elementObserve: { _ in Issue.record("Unexpected observe during action"); return .null },
        elementAction: { _ in
            try AccessibilityDriver.validateObservedTargetIdentity(
                session: session, ref: "ax_7_2", target: initialTarget
            )
            PluginRuntime.retireObservedElementEpoch(session)
            return .object(["semanticAction": .string("invoke")])
        }
    )
    #expect(action["semanticAction"]?.stringValue == "invoke")
    #expect(session.record.snapshotRevision == 8)
    #expect(session.record.lastObservedAt == nil)
    #expect(session.elements.isEmpty)
    #expect(session.elementWindowRefs.isEmpty)

    do {
        try AccessibilityDriver.validateObservedTargetIdentity(
            session: session, ref: "ax_7_2", target: initialTarget
        )
        Issue.record("Semantic mutation must retire the authorizing observation epoch")
    } catch let error as PluginError {
        #expect(error.code == "COMPUTER_ELEMENT_OBSERVATION_STALE")
    }

    let freshTarget = bindObservation(revision: 8)
    let secondObservation = try runtime.execute(
        ComputerExecuteParams(
            capability: ComputerProviderProtocol.elementObserveCapability,
            protocolVersion: ComputerProviderProtocol.elementProtocolVersion,
            arguments: .object(["interactionId": .string("desk_behavior")])
        ),
        nativeAction: { _, _ in Issue.record("Unexpected native action"); return .null },
        elementObserve: { _ in
            observeCount += 1
            try AccessibilityDriver.validateObservedTargetIdentity(
                session: session, ref: "ax_8_2", target: freshTarget
            )
            return .object([
                "ref": .string("ax_8_2"),
                "snapshotRevision": .number(8),
                "windowRef": .string("ax_8_1"),
            ])
        },
        elementAction: { _ in Issue.record("Unexpected action during re-observe"); return .null }
    )
    #expect(observeCount == 2)
    #expect(secondObservation["snapshotRevision"]?.intValue == 8)
    #expect(secondObservation["ref"]?.stringValue == "ax_8_2")
}


@Test func consoleUnlockCapabilityIsIndependentAndRoutesOnlyDedicatedAction() throws {
    var nativeCalls = 0
    var consoleCalls = 0
    let runtime = ComputerProviderRuntime(browserAutomation: BrowserAutomationBroker { _, _, _ in
        BrowserAutomationCommandResult(status: 0, stdout: "ok")
    })
    #expect(runtime.capabilities.contains {
        $0.capabilityId == ComputerProviderProtocol.consoleUnlockCapability && $0.actions == ["unlock_console"]
    })

    let result = try runtime.execute(
        ComputerExecuteParams(
            capability: ComputerProviderProtocol.consoleUnlockCapability,
            protocolVersion: ComputerProviderProtocol.legacyProtocolVersion,
            arguments: .object([
                "action": .string("unlock_console"),
                "authorization": .object(["kind": .string("explicit_single_use")]),
            ])
        ),
        nativeAction: { _, _ in nativeCalls += 1; return .null },
        elementObserve: { _ in .null },
        elementAction: { _ in .null },
        consoleUnlock: { arguments in
            consoleCalls += 1
            #expect(arguments["action"] == nil)
            return .object(["routed": .bool(true)])
        }
    )
    #expect(result["routed"]?.boolValue == true)
    #expect(consoleCalls == 1)
    #expect(nativeCalls == 0)

    do {
        _ = try runtime.execute(
            ComputerExecuteParams(
                capability: ComputerProviderProtocol.consoleUnlockCapability,
                protocolVersion: ComputerProviderProtocol.legacyProtocolVersion,
                arguments: .object(["action": .string("desktop_key")])
            ),
            nativeAction: { _, _ in nativeCalls += 1; return .null },
            elementObserve: { _ in .null },
            elementAction: { _ in .null },
            consoleUnlock: { _ in Issue.record("Unexpected console route"); return .null }
        )
        Issue.record("Expected dedicated-action rejection")
    } catch let error as PluginError {
        #expect(error.code == "COMPUTER_ACTION_UNSUPPORTED")
    }
    #expect(nativeCalls == 0)
}

@Test func consoleUnlockRequiresExplicitSingleUseAuthorizationBeforeInput() throws {
    var submitted = false
    let coordinator = ConsoleUnlockCoordinator(
        isLocked: { true },
        loginwindow: { ConsoleLoginwindowIdentity(pid: 42, bundleIdentifier: "com.apple.loginwindow") },
        accessibilityTrusted: { true },
        submitCredential: { _ in submitted = true },
        sleep: { _ in },
        now: Date.init,
        verificationTimeout: 0
    )
    do {
        _ = try coordinator.execute(.object(["credential": .string("fixture-only")]))
        Issue.record("Expected authorization rejection")
    } catch let error as PluginError {
        #expect(error.code == "CONSOLE_UNLOCK_EXPLICIT_AUTHORIZATION_REQUIRED")
    }
    #expect(!submitted)
}

@Test func consoleUnlockVerifiesLockedToUnlockedAndDoesNotReturnCredential() throws {
    var locked = true
    let invocation = UUID().uuidString
    let coordinator = ConsoleUnlockCoordinator(
        isLocked: { locked },
        loginwindow: { ConsoleLoginwindowIdentity(pid: 42, bundleIdentifier: "com.apple.loginwindow") },
        accessibilityTrusted: { true },
        submitCredential: { credential in
            #expect(credential == "fixture-only")
            locked = false
        },
        sleep: { _ in }
    )
    let result = try coordinator.execute(.object([
        "authorization": .object([
            "kind": .string("explicit_single_use"),
            "confirmed": .bool(true),
            "invocation_id": .string(invocation),
        ]),
        "credential": .string("fixture-only"),
    ]))
    #expect(result["unlocked"]?.boolValue == true)
    #expect(result["verified"]?.boolValue == true)
    #expect(result["credential"] == nil)
}

@Test func consoleUnlockUnchangedLockStateIsTypedAndCredentialFree() throws {
    let invocation = UUID().uuidString
    let fixture = "fixture-credential-never-echo"
    let coordinator = ConsoleUnlockCoordinator(
        isLocked: { true },
        loginwindow: { ConsoleLoginwindowIdentity(pid: 42, bundleIdentifier: "com.apple.loginwindow") },
        accessibilityTrusted: { true },
        submitCredential: { _ in },
        sleep: { _ in },
        now: Date.init,
        verificationTimeout: 0
    )
    do {
        _ = try coordinator.execute(.object([
            "authorization": .object([
                "kind": .string("explicit_single_use"),
                "confirmed": .bool(true),
                "invocation_id": .string(invocation),
            ]),
            "credential": .string(fixture),
        ]))
        Issue.record("Expected unchanged-lock rejection")
    } catch let error as PluginError {
        #expect(error.code == "CONSOLE_UNLOCK_CREDENTIAL_NOT_ACCEPTED")
        #expect(!error.description.contains(fixture))
    }
}

@Test func consoleUnlockAuthorizationCannotBeReplayed() throws {
    let invocation = UUID().uuidString
    let gate = ConsoleUnlockAttemptGate()
    let coordinator = ConsoleUnlockCoordinator(
        gate: gate,
        isLocked: { false },
        loginwindow: { nil },
        accessibilityTrusted: { true },
        submitCredential: { _ in Issue.record("Unexpected input") },
        sleep: { _ in }
    )
    let request: JSONValue = .object([
        "authorization": .object([
            "kind": .string("explicit_single_use"),
            "confirmed": .bool(true),
            "invocation_id": .string(invocation),
        ]),
        "credential": .string("fixture-only"),
    ])
    do { _ = try coordinator.execute(request) } catch { }
    do {
        _ = try coordinator.execute(request)
        Issue.record("Expected replay rejection")
    } catch let error as PluginError {
        #expect(error.code == "CONSOLE_UNLOCK_AUTHORIZATION_REPLAYED")
    }
}
