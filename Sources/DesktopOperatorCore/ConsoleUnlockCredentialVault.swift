import AppKit
import Foundation

final class ConsoleUnlockCredentialVault: @unchecked Sendable {
    private struct Entry {
        let handle: String
        let credential: String
        let expiresAt: Date
    }

    private let lock = NSLock()
    private let ttl: TimeInterval
    private var entry: Entry?

    init(ttl: TimeInterval = 120) {
        self.ttl = max(15, min(ttl, 300))
    }

    func store(_ credential: String, at now: Date) -> (handle: String, expiresAt: Date) {
        lock.lock()
        defer { lock.unlock() }
        let handle = UUID().uuidString.lowercased()
        let expiresAt = now.addingTimeInterval(ttl)
        entry = Entry(handle: handle, credential: credential, expiresAt: expiresAt)
        return (handle, expiresAt)
    }

    func consume(handle: String, at now: Date) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        guard UUID(uuidString: handle) != nil else {
            throw PluginError(
                code: "CONSOLE_UNLOCK_CREDENTIAL_HANDLE_INVALID",
                message: "Console-unlock credential handle is invalid.",
                retryable: false,
                domain: "authorization"
            )
        }
        guard let current = entry, current.handle == handle else {
            throw PluginError(
                code: "CONSOLE_UNLOCK_CREDENTIAL_HANDLE_UNAVAILABLE",
                message: "Console-unlock credential handle is unavailable or has already been consumed.",
                retryable: false,
                domain: "authorization"
            )
        }
        guard now <= current.expiresAt else {
            entry = nil
            throw PluginError(
                code: "CONSOLE_UNLOCK_CREDENTIAL_HANDLE_EXPIRED",
                message: "Console-unlock credential handle expired before it could be used.",
                retryable: false,
                domain: "authorization"
            )
        }
        entry = nil
        return current.credential
    }
}

enum ConsoleUnlockCredentialPrompt {
    static func prompt() throws -> String {
        guard !ApplicationDriver.currentSessionIsLocked() else {
            throw PluginError(
                code: "CONSOLE_UNLOCK_PREPARE_REQUIRES_UNLOCKED_CONSOLE",
                message: "Prepare console unlock while the macOS console is unlocked so the credential can be entered locally.",
                retryable: false,
                domain: "console"
            )
        }
        if Thread.isMainThread {
            return try MainActor.assumeIsolated {
                try promptOnMainActor()
            }
        }
        return try DispatchQueue.main.sync {
            try MainActor.assumeIsolated {
                try promptOnMainActor()
            }
        }
    }

    @MainActor
    private static func promptOnMainActor() throws -> String {
        guard !ApplicationDriver.currentSessionIsLocked() else {
            throw PluginError(
                code: "CONSOLE_UNLOCK_PREPARE_REQUIRES_UNLOCKED_CONSOLE",
                message: "The console locked before local credential preparation could begin.",
                retryable: false,
                domain: "console"
            )
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.activate(ignoringOtherApps: true)

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "macOS login password"

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Prepare Forge console unlock"
        alert.informativeText = "Enter the macOS login password locally. It stays only in Forge Desktop Operator memory, expires shortly, and is consumed after one unlock attempt."
        alert.accessoryView = field
        alert.addButton(withTitle: "Prepare")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        let credential = field.stringValue
        field.stringValue = ""

        guard response == .alertFirstButtonReturn else {
            throw PluginError(
                code: "CONSOLE_UNLOCK_PREPARATION_CANCELLED",
                message: "Local console-unlock credential preparation was cancelled.",
                retryable: false,
                domain: "authorization"
            )
        }
        guard !credential.isEmpty, credential.lengthOfBytes(using: .utf8) <= 1_024 else {
            throw PluginError(
                code: "CONSOLE_UNLOCK_CREDENTIAL_REQUIRED",
                message: "A bounded local console-unlock credential is required.",
                retryable: false,
                domain: "authorization"
            )
        }
        return credential
    }
}
