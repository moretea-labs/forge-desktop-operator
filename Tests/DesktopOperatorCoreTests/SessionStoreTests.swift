import Foundation
import Testing
@testable import DesktopOperatorCore

private struct PersistedSessionFixture: Codable {
    let schemaVersion: Int
    let sessions: [DesktopSessionRecord]
}

private func temporarySessionStorePath() throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("forge-desktop-session-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.appendingPathComponent("desktop-sessions.json").path
}

@Test func desktopSessionStoreRestoresStableIdentityAndResetsEphemeralEvidence() throws {
    let path = try temporarySessionStorePath()
    defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
    let original = DesktopSessionRecord(
        interactionId: "desk_persisted",
        pid: 42,
        bundleIdentifier: "com.example.Editor",
        appName: "Editor",
        createdAt: Date(timeIntervalSince1970: 100),
        lastObservedAt: Date(timeIntervalSince1970: 200),
        snapshotRevision: 9
    )
    let fixture = PersistedSessionFixture(schemaVersion: 1, sessions: [original])
    try JSONEncoder.repoHarness.encode(fixture).write(to: URL(fileURLWithPath: path), options: [.atomic])

    let store = DesktopSessionStore(statePath: path) { record in
        var rebound = record
        rebound.pid = 84
        rebound.lastObservedAt = nil
        rebound.snapshotRevision = 0
        return rebound
    }
    let restored = try store.get("desk_persisted")
    #expect(restored.record.interactionId == "desk_persisted")
    #expect(restored.record.pid == 84)
    #expect(restored.record.lastObservedAt == nil)
    #expect(restored.record.snapshotRevision == 0)
    #expect(restored.elements.isEmpty)
    #expect(restored.lastVisualEvidence == nil)

    try store.checkpoint(restored)
    let restarted = DesktopSessionStore(statePath: path) { $0 }
    #expect(try restarted.get("desk_persisted").record.pid == 84)
}

@Test func desktopSessionStoreFailsClosedOnCorruptPersistence() throws {
    let path = try temporarySessionStorePath()
    defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
    try Data("{not-json".utf8).write(to: URL(fileURLWithPath: path), options: [.atomic])

    let store = DesktopSessionStore(statePath: path) { $0 }
    #expect(store.loadError != nil)
    #expect(throws: PluginError.self) {
        _ = try store.remove("desk_missing")
    }
    let health = PluginRuntime(socketPath: "/tmp/desktop-operator-session-store-test.sock", sessions: store).health()
    #expect(health.state == "degraded")
    #expect(health.warnings.contains { $0.contains("session persistence") })
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
