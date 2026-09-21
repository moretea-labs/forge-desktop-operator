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
    public var applicationOwnership: DesktopApplicationLaunchOwnership = .preexisting
    public var ownedProcessIdentifier: Int32? = nil
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
    /// Ephemeral observation-local element -> AX window ref binding. Never persisted.
    public var elementWindowRefs: [String: String] = [:]
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

/// Process-local provider bindings only. Forge owns durable Computer target/session authority.
/// Restart intentionally drops every interaction id, AX handle and visual evidence binding.
public final class DesktopSessionStore {
    public typealias ApplicationResolver = (DesktopSessionRecord) -> DesktopSessionRecord?

    private var sessions: [String: DesktopSessionState] = [:]
    private let lock = NSLock()
    private let applicationResolver: ApplicationResolver

    public init(
        applicationResolver: @escaping ApplicationResolver = DesktopSessionStore.resolveLiveApplication
    ) {
        self.applicationResolver = applicationResolver
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return sessions.count
    }

    public func create(
        application: NSRunningApplication,
        reuseExisting: Bool = true,
        applicationOwnership: DesktopApplicationLaunchOwnership = .preexisting,
        ownedProcessIdentifier: Int32? = nil
    ) throws -> DesktopSessionState {
        guard !application.isTerminated else {
            throw PluginError(code: "APP_TERMINATED", message: "The selected application is no longer running", retryable: true)
        }
        lock.lock()
        defer { lock.unlock() }
        if reuseExisting, let existing = reusableSessionLocked(application: application) {
            existing.withLock {
                existing.record.pid = application.processIdentifier
                existing.elements.removeAll(keepingCapacity: false)
                existing.elementWindowRefs.removeAll(keepingCapacity: false)
                existing.lastRootElement = nil
            }
            return existing
        }
        if applicationOwnership == .providerLaunched, ownedProcessIdentifier != application.processIdentifier {
            throw PluginError(code: "APP_LAUNCH_PROVENANCE_INVALID", message: "Provider-launched session ownership requires the exact launched process identifier", retryable: false, domain: "session")
        }
        if applicationOwnership == .preexisting, ownedProcessIdentifier != nil {
            throw PluginError(code: "APP_LAUNCH_PROVENANCE_INVALID", message: "Preexisting application sessions cannot claim an owned process identifier", retryable: false, domain: "session")
        }
        let id = "desk_\(UUID().uuidString.lowercased())"
        let record = DesktopSessionRecord(
            interactionId: id,
            pid: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            appName: application.localizedName ?? application.bundleIdentifier ?? "Unknown",
            createdAt: Date(),
            lastObservedAt: nil,
            snapshotRevision: 0,
            applicationOwnership: applicationOwnership,
            ownedProcessIdentifier: ownedProcessIdentifier
        )
        let state = DesktopSessionState(record: record)
        sessions[id] = state
        return state
    }

    public func get(_ id: String) throws -> DesktopSessionState {
        lock.lock()
        defer { lock.unlock() }
        guard let state = sessions[id] else {
            throw PluginError(code: "SESSION_NOT_FOUND", message: "Desktop provider binding \(id) was not found; rebind through Forge after provider restart", retryable: true, domain: "session")
        }
        let current = state.withLock { state.record }
        guard let rebound = applicationResolver(current) else {
            throw PluginError(
                code: "SESSION_TARGET_NOT_RUNNING",
                message: "Desktop provider binding \(id) targets an application that is no longer running",
                retryable: true,
                domain: "session"
            )
        }
        if rebound.pid != current.pid {
            let replacement = restoredState(from: rebound, invalidateApplicationOwnership: true)
            sessions[id] = replacement
            return replacement
        }
        return state
    }

    @discardableResult
    public func remove(_ id: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessions.removeValue(forKey: id) != nil
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

    private func restoredState(from record: DesktopSessionRecord, invalidateApplicationOwnership: Bool = false) -> DesktopSessionState {
        var reset = record
        reset.lastObservedAt = nil
        reset.snapshotRevision = 0
        if invalidateApplicationOwnership {
            reset.applicationOwnership = .preexisting
            reset.ownedProcessIdentifier = nil
        }
        return DesktopSessionState(record: reset)
    }
}
