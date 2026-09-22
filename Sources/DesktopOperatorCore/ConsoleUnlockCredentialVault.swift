import AppKit
import Foundation
import Security

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

protocol ConsoleUnlockRecoveryCredentialStoring: Sendable {
    func isEnrolled() throws -> Bool
    func read() throws -> String?
    func write(_ credential: String) throws
    func delete() throws
}

final class ConsoleUnlockRecoveryCredentialStore: ConsoleUnlockRecoveryCredentialStoring, @unchecked Sendable {
    private let service: String
    private let account: String

    init(
        service: String = "com.moretea.forge.desktop-operator.console-unlock",
        account: String = NSUserName()
    ) {
        self.service = service
        self.account = account
    }

    func isEnrolled() throws -> Bool {
        var query = identityQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw keychainError("inspect", status)
        }
    }

    func read() throws -> String? {
        var query = identityQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let credential = String(data: data, encoding: .utf8),
                  !credential.isEmpty else {
                throw PluginError(
                    code: "CONSOLE_UNLOCK_RECOVERY_CREDENTIAL_INVALID",
                    message: "The provider-local unattended-unlock credential is unreadable.",
                    retryable: false,
                    domain: "authorization"
                )
            }
            return credential
        case errSecItemNotFound:
            return nil
        default:
            throw keychainError("read", status)
        }
    }

    func write(_ credential: String) throws {
        let data = Data(credential.utf8)
        var attributes = identityQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = kCFBooleanFalse

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess { return }
        if status == errSecDuplicateItem {
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let updateStatus = SecItemUpdate(identityQuery() as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw keychainError("update", updateStatus) }
            return
        }
        throw keychainError("write", status)
    }

    func delete() throws {
        let status = SecItemDelete(identityQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError("delete", status)
        }
    }

    private func identityQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func keychainError(_ operation: String, _ status: OSStatus) -> PluginError {
        PluginError(
            code: "CONSOLE_UNLOCK_RECOVERY_KEYCHAIN_UNAVAILABLE",
            message: "macOS Keychain could not \(operation) the provider-local unattended-unlock credential (status \(status)).",
            retryable: status == errSecInteractionNotAllowed,
            domain: "authorization"
        )
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
        alert.messageText = "Authorize Forge console recovery"
        alert.informativeText = "Enter the macOS login password locally. Forge Desktop Operator keeps it inside the native provider boundary; temporary preparation stays in memory and unattended enrollment stores it only in this Mac's Keychain."
        alert.accessoryView = field
        alert.addButton(withTitle: "Authorize")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        let credential = field.stringValue
        field.stringValue = ""

        guard response == .alertFirstButtonReturn else {
            throw PluginError(
                code: "CONSOLE_UNLOCK_PREPARATION_CANCELLED",
                message: "Local console-unlock credential authorization was cancelled.",
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
