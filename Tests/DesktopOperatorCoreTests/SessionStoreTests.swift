import AppKit
import Foundation
import Testing
@testable import DesktopOperatorCore

@Test func desktopSessionStoreRestartDropsProviderBindings() throws {
    guard let application = NSWorkspace.shared.runningApplications.first(where: { !$0.isTerminated }) else {
        return
    }
    let firstStore = DesktopSessionStore(applicationResolver: { $0 })
    let state = try firstStore.create(application: application, reuseExisting: true)
    state.visualRevision = 3
    state.lastVisualEvidence = DesktopVisualEvidence(
        revision: 3,
        windowId: 123,
        frame: DesktopFrame(x: 10, y: 20, width: 300, height: 200),
        capturedAt: Date()
    )
    let interactionId = state.record.interactionId

    let restartedStore = DesktopSessionStore(applicationResolver: { $0 })
    #expect(restartedStore.count == 0)
    #expect(throws: PluginError.self) {
        _ = try restartedStore.get(interactionId)
    }
}

@Test func desktopSessionStoreReusePreservesLaunchOwnershipAndFreshVisualEvidence() throws {
    let store = DesktopSessionStore(applicationResolver: { $0 })
    guard let application = NSWorkspace.shared.runningApplications.first(where: { !$0.isTerminated }) else {
        return
    }
    let first = try store.create(
        application: application,
        reuseExisting: true,
        applicationOwnership: .providerLaunched,
        ownedProcessIdentifier: application.processIdentifier
    )
    let evidence = DesktopVisualEvidence(
        revision: 4,
        windowId: 123,
        frame: DesktopFrame(x: 10, y: 20, width: 300, height: 200),
        capturedAt: Date()
    )
    first.visualRevision = 4
    first.lastVisualEvidence = evidence
    first.elementWindowRefs["ax_4_2"] = "ax_4_1"
    first.elementFrames["ax_4_1"] = DesktopFrame(x: 10, y: 20, width: 30, height: 40)

    let reused = try store.create(application: application, reuseExisting: true)
    #expect(reused === first)
    #expect(reused.record.applicationOwnership == .providerLaunched)
    #expect(reused.record.ownedProcessIdentifier == application.processIdentifier)
    #expect(reused.visualRevision == 4)
    #expect(reused.lastVisualEvidence == evidence)
    #expect(reused.elementWindowRefs.isEmpty)
    #expect(reused.elementFrames.isEmpty)
}

@Test func desktopSessionStoreRebindsPidAndDropsEphemeralHandles() throws {
    guard let application = NSWorkspace.shared.runningApplications.first(where: { !$0.isTerminated }) else {
        return
    }
    var nextPid = application.processIdentifier
    let store = DesktopSessionStore { record in
        var rebound = record
        rebound.pid = nextPid
        return rebound
    }
    let state = try store.create(application: application, reuseExisting: false)
    state.visualRevision = 7
    state.lastVisualEvidence = DesktopVisualEvidence(
        revision: 7,
        windowId: 456,
        frame: DesktopFrame(x: 0, y: 0, width: 100, height: 100),
        capturedAt: Date()
    )
    nextPid = application.processIdentifier == Int32.max ? application.processIdentifier - 1 : application.processIdentifier + 1

    let rebound = try store.get(state.record.interactionId)
    #expect(rebound !== state)
    #expect(rebound.record.pid == nextPid)
    #expect(rebound.record.applicationOwnership == .preexisting)
    #expect(rebound.record.ownedProcessIdentifier == nil)
    #expect(rebound.record.snapshotRevision == 0)
    #expect(rebound.elements.isEmpty)
    #expect(rebound.elementWindowRefs.isEmpty)
    #expect(rebound.lastVisualEvidence == nil)
}

@Test func desktopSessionStableIdentityPrefersBundleIdentifier() {
    let first = DesktopSessionRecord(
        interactionId: "desk_one",
        pid: 1,
        bundleIdentifier: "com.example.Editor",
        appName: "Localized Editor",
        createdAt: Date(),
        lastObservedAt: nil,
        snapshotRevision: 0
    )
    var second = first
    second.pid = 2
    #expect(DesktopSessionStore.stableApplicationKey(first) == DesktopSessionStore.stableApplicationKey(second))
    #expect(DesktopSessionStore.stableApplicationKey(first) == "bundle:com.example.editor")
}


@Test func desktopExactProcessSessionRejectsWrongPidBeforeImplicitMigration() throws {
    guard let application = NSWorkspace.shared.runningApplications.first(where: { !$0.isTerminated && $0.processIdentifier > 0 }) else {
        return
    }
    let originalPid = application.processIdentifier
    let wrongPid = originalPid == Int32.max ? originalPid - 1 : originalPid + 1
    let store = DesktopSessionStore()
    #expect(throws: PluginError.self) {
        _ = try store.create(application: application, reuseExisting: false, exactProcessIdentifier: wrongPid)
    }
    let session = try store.create(
        application: application, reuseExisting: false, exactProcessIdentifier: originalPid,
        exactBundlePath: "/Applications/definitely-not-the-bound-application.app"
    )
    #expect(session.exactProcessIdentifier == originalPid)
    #expect(throws: PluginError.self) { _ = try store.get(session.record.interactionId) }
    #expect(store.count == 1)
}

@Test func exactDesktopProcessSelectionFailsClosedWithoutLaunch() throws {
    #expect(throws: PluginError.self) {
        _ = try ApplicationDriver.ensureRunningWithProvenance(
            bundleIdentifier: "com.example.wrong", appName: nil, launch: false,
            exactProcessIdentifier: Int32.max
        )
    }
    #expect(throws: PluginError.self) {
        _ = try ApplicationDriver.ensureRunningWithProvenance(
            bundleIdentifier: "com.example.wrong", appName: nil, launch: true,
            exactProcessIdentifier: 1
        )
    }
    #expect(throws: PluginError.self) {
        _ = try ApplicationDriver.ensureRunningWithProvenance(
            bundleIdentifier: "com.example.wrong", appName: nil, launch: false,
            exactBundlePath: "/Applications/Other.app"
        )
    }
}


@Test func exactDesktopProcessSelectionBindsTheActualRunningApplication() throws {
    guard let application = NSWorkspace.shared.runningApplications.first(where: {
        !$0.isTerminated && $0.processIdentifier > 0 && $0.bundleIdentifier != nil && $0.bundleURL != nil
    }), let bundleId = application.bundleIdentifier, let bundlePath = application.bundleURL?.path else {
        return
    }
    let selected = try ApplicationDriver.ensureRunningWithProvenance(
        bundleIdentifier: bundleId, appName: nil, launch: false,
        exactProcessIdentifier: application.processIdentifier, exactBundlePath: bundlePath
    )
    #expect(selected.application.processIdentifier == application.processIdentifier)
    #expect(selected.ownership == .preexisting)
    #expect(selected.ownedProcessIdentifier == nil)
    #expect(throws: PluginError.self) {
        _ = try ApplicationDriver.ensureRunningWithProvenance(
            bundleIdentifier: bundleId, appName: nil, launch: false,
            exactProcessIdentifier: application.processIdentifier,
            exactBundlePath: "/Applications/not-the-same-preview.app"
        )
    }
}
