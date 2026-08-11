import AppKit
import ApplicationServices
import Foundation

public struct DesktopSessionRecord: Codable, Equatable, Sendable {
    public let interactionId: String
    public let pid: Int32
    public let bundleIdentifier: String?
    public let appName: String
    public let createdAt: Date
    public var lastObservedAt: Date?
    public var snapshotRevision: Int
}

public final class DesktopSessionState {
    public var record: DesktopSessionRecord
    public var elements: [String: AXUIElement] = [:]
    public var lastRootElement: AXUIElement?
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
    private var sessions: [String: DesktopSessionState] = [:]
    private let lock = NSLock()

    public init() {}

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return sessions.count
    }

    public func create(application: NSRunningApplication) throws -> DesktopSessionState {
        guard !application.isTerminated else {
            throw PluginError(code: "APP_TERMINATED", message: "The selected application is no longer running", retryable: true)
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
        lock.lock(); defer { lock.unlock() }
        sessions[id] = state
        return state
    }

    public func get(_ id: String) throws -> DesktopSessionState {
        lock.lock(); defer { lock.unlock() }
        guard let state = sessions[id] else {
            throw PluginError(code: "SESSION_NOT_FOUND", message: "Desktop session \(id) was not found", retryable: false, domain: "session")
        }
        return state
    }

    @discardableResult
    public func remove(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sessions.removeValue(forKey: id) != nil
    }

    public func records() -> [DesktopSessionRecord] {
        lock.lock(); defer { lock.unlock() }
        return sessions.values.map { state in
            state.withLock { state.record }
        }.sorted { $0.createdAt < $1.createdAt }
    }
}
