import AppKit
import ApplicationServices
import Foundation

public struct DesktopSessionRecord: Codable, Equatable, Sendable {
    public let interactionId: String
    public var pid: Int32
    public let bundleIdentifier: String?
    public let appName: String
    public let createdAt: Date
    public var lastObservedAt: Date?
    public var snapshotRevision: Int
}

public struct DesktopVisualEvidence: Equatable, Sendable {
    public let revision: Int
    public let windowId: UInt32
    public let frame: DesktopFrame
    public let capturedAt: Date
}

public final class DesktopSessionState {
    public var record: DesktopSessionRecord
    public var elements: [String: AXUIElement] = [:]
    public var lastRootElement: AXUIElement?
    public var visualRevision: Int = 0
    public var lastVisualEvidence: DesktopVisualEvidence?
    private let lock = NSRecursiveLock()

    public init(record: DesktopSessionRecord) {
        self.record = record
    }

    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

public final class DesktopSessionStore {
    private struct PersistedStore: Codable {
        let schemaVersion: Int
        let sessions: [DesktopSessionRecord]
    }

    public typealias ApplicationResolver = (DesktopSessionRecord) -> DesktopSessionRecord?

    private var sessions: [String: DesktopSessionState] = [:]
    private let lock = NSLock()
    private let statePath: String?
    private let applicationResolver: ApplicationResolver
    public private(set) var loadError: String?

    public init(
        statePath: String? = PluginPaths.sessionStorePath,
        applicationResolver: @escaping ApplicationResolver = DesktopSessionStore.resolveLiveApplication
    ) {
        self.statePath = statePath
        self.applicationResolver = applicationResolver
        loadPersistedSessions()
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return sessions.count
    }

    public func create(application: NSRunningApplication, reuseExisting: Bool = true) throws -> DesktopSessionState {
        guard !application.isTerminated else {
            throw PluginError(code: "APP_TERMINATED", message: "The selected application is no longer running", retryable: true)
        }
        try assertWritable()
        lock.lock()
        defer { lock.unlock() }
        if reuseExisting, let existing = reusableSessionLocked(application: application) {
            existing.withLock {
                existing.record.pid = application.processIdentifier
                existing.elements.removeAll(keepingCapacity: false)
                existing.lastRootElement = nil
                existing.visualRevision = 0
                existing.lastVisualEvidence = nil
            }
            try persistLocked()
            return existing
        }
        let id = "desk_\(UUID().uuidString.lowercased())"
        let record = DesktopSessionRecord(
            interactionId: id,
            pid: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            appName: application.localizedName ?? application.bundleIdentifier ?? "Unknown",
            createdAt: Date(),
            lastObservedAt: nil,
            snapshotRevision: 0
        )
        let state = DesktopSessionState(record: record)
        sessions[id] = state
        try persistLocked()
        return state
    }

    public func get(_ id: String) throws -> DesktopSessionState {
        lock.lock()
        defer { lock.unlock() }
        guard let state = sessions[id] else {
            throw PluginError(code: "SESSION_NOT_FOUND", message: "Desktop session \(id) was not found", retryable: false, domain: "session")
        }
        let current = state.withLock { state.record }
        guard let rebound = applicationResolver(current) else {
            throw PluginError(
                code: "SESSION_TARGET_NOT_RUNNING",
                message: "Desktop session \(id) is retained, but its application is not currently running",
                retryable: true,
                domain: "session"
            )
        }
        if rebound.pid != current.pid {
            let replacement = restoredState(from: rebound)
            sessions[id] = replacement
            try persistLocked()
            return replacement
        }
        return state
    }

    @discardableResult
    public func remove(_ id: String) throws -> Bool {
        try assertWritable()
        lock.lock()
        defer { lock.unlock() }
        let removed = sessions.removeValue(forKey: id) != nil
        if removed { try persistLocked() }
        return removed
    }

    public func checkpoint(_ state: DesktopSessionState) throws {
        try assertWritable()
        lock.lock()
        defer { lock.unlock() }
        guard sessions[state.record.interactionId] === state else { return }
        try persistLocked()
    }

    public func records() -> [DesktopSessionRecord] {
        lock.lock(); defer { lock.unlock() }
        return sessions.values.map { state in
            state.withLock { state.record }
        }.sorted { $0.createdAt < $1.createdAt }
    }

    public static func stableApplicationKey(_ record: DesktopSessionRecord) -> String {
        if let bundleIdentifier = record.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleIdentifier.isEmpty {
            return "bundle:\(bundleIdentifier.lowercased())"
        }
        return "name:\(record.appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    public static func resolveLiveApplication(_ record: DesktopSessionRecord) -> DesktopSessionRecord? {
        guard let application = ApplicationDriver.findRunning(
            bundleIdentifier: record.bundleIdentifier,
            appName: record.appName
        ) else { return nil }
        var rebound = record
        rebound.pid = application.processIdentifier
        rebound.lastObservedAt = nil
        rebound.snapshotRevision = 0
        return rebound
    }

    private func reusableSessionLocked(application: NSRunningApplication) -> DesktopSessionState? {
        let candidate = DesktopSessionRecord(
            interactionId: "candidate",
            pid: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            appName: application.localizedName ?? application.bundleIdentifier ?? "Unknown",
            createdAt: Date(),
            lastObservedAt: nil,
            snapshotRevision: 0
        )
        let key = Self.stableApplicationKey(candidate)
        return sessions.values
            .filter { state in state.withLock { Self.stableApplicationKey(state.record) == key } }
            .sorted { left, right in
                left.withLock { left.record.createdAt } < right.withLock { right.record.createdAt }
            }
            .first
    }

    private func restoredState(from record: DesktopSessionRecord) -> DesktopSessionState {
        var reset = record
        reset.lastObservedAt = nil
        reset.snapshotRevision = 0
        return DesktopSessionState(record: reset)
    }

    private func loadPersistedSessions() {
        guard let statePath, FileManager.default.fileExists(atPath: statePath) else { return }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: statePath))
            let persisted = try JSONDecoder.repoHarness.decode(PersistedStore.self, from: data)
            guard persisted.schemaVersion == 1, persisted.sessions.count <= 500 else {
                throw PluginError(code: "SESSION_STORE_SCHEMA_UNSUPPORTED", message: "Desktop session store schema or size is unsupported", domain: "session")
            }
            for record in persisted.sessions {
                guard record.interactionId.hasPrefix("desk_"), !record.appName.isEmpty else {
                    throw PluginError(code: "SESSION_STORE_CORRUPT", message: "Desktop session store contains an invalid record", domain: "session")
                }
                let reconciled = applicationResolver(record) ?? record
                sessions[record.interactionId] = restoredState(from: reconciled)
            }
        } catch {
            sessions.removeAll()
            loadError = (error as? PluginError)?.message ?? error.localizedDescription
        }
    }

    private func assertWritable() throws {
        if let loadError {
            throw PluginError(
                code: "SESSION_STORE_UNAVAILABLE",
                message: "Desktop session persistence is unavailable until the corrupt store is repaired: \(loadError)",
                retryable: false,
                domain: "session"
            )
        }
    }

    private func persistLocked() throws {
        guard let statePath else { return }
        let directory = URL(fileURLWithPath: statePath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let records = sessions.values.map { state in state.withLock { state.record } }.sorted { $0.createdAt < $1.createdAt }
        let data = try JSONEncoder.repoHarness.encode(PersistedStore(schemaVersion: 1, sessions: records))
        try data.write(to: URL(fileURLWithPath: statePath), options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: statePath)
    }
}
