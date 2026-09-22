import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct ConsoleLoginwindowIdentity: Equatable, Sendable {
    let pid: pid_t
    let bundleIdentifier: String
}

final class ConsoleUnlockAttemptGate: @unchecked Sendable {
    private let lock = NSLock()
    private let maxAttempts: Int
    private let attemptWindow: TimeInterval
    private let replayRetention: TimeInterval
    private var attempts: [Date] = []
    private var consumedInvocations: [String: Date] = [:]

    init(maxAttempts: Int = 3, attemptWindow: TimeInterval = 300, replayRetention: TimeInterval = 600) {
        self.maxAttempts = maxAttempts
        self.attemptWindow = attemptWindow
        self.replayRetention = replayRetention
    }

    func consumeAuthorization(invocationId: String, at now: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        consumedInvocations = consumedInvocations.filter { now.timeIntervalSince($0.value) <= replayRetention }
        guard consumedInvocations[invocationId] == nil else {
            throw PluginError(
                code: "CONSOLE_UNLOCK_AUTHORIZATION_REPLAYED",
                message: "This explicit console-unlock authorization has already been consumed.",
                retryable: false,
                domain: "authorization"
            )
        }
        consumedInvocations[invocationId] = now
    }

    func consumeAttempt(at now: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        attempts.removeAll { now.timeIntervalSince($0) > attemptWindow }
        guard attempts.count < maxAttempts else {
            throw PluginError(
                code: "CONSOLE_UNLOCK_RATE_LIMITED",
                message: "The bounded console-unlock attempt limit has been reached. A later explicit authorization is required.",
                retryable: false,
                domain: "authorization"
            )
        }
        attempts.append(now)
    }
}

final class ConsoleUnlockCoordinator {
    typealias LockedProvider = () -> Bool
    typealias LoginwindowProvider = () -> ConsoleLoginwindowIdentity?
    typealias AccessibilityProvider = () -> Bool
    typealias CredentialSubmitter = (_ credential: String) throws -> Void
    typealias CredentialPrompter = () throws -> String
    typealias Sleeper = (_ seconds: TimeInterval) -> Void
    typealias Clock = () -> Date

    private let gate: ConsoleUnlockAttemptGate
    private let credentialVault: ConsoleUnlockCredentialVault
    private let recoveryCredentialStore: ConsoleUnlockRecoveryCredentialStoring
    private let isLocked: LockedProvider
    private let loginwindow: LoginwindowProvider
    private let accessibilityTrusted: AccessibilityProvider
    private let submitCredential: CredentialSubmitter
    private let promptCredential: CredentialPrompter
    private let sleep: Sleeper
    private let now: Clock
    private let verificationTimeout: TimeInterval
    private let verificationInterval: TimeInterval

    init(
        gate: ConsoleUnlockAttemptGate = ConsoleUnlockAttemptGate(),
        credentialVault: ConsoleUnlockCredentialVault = ConsoleUnlockCredentialVault(),
        recoveryCredentialStore: ConsoleUnlockRecoveryCredentialStoring = ConsoleUnlockRecoveryCredentialStore(),
        isLocked: @escaping LockedProvider = ApplicationDriver.currentSessionIsLocked,
        loginwindow: @escaping LoginwindowProvider = ConsoleUnlockCoordinator.currentLoginwindow,
        accessibilityTrusted: @escaping AccessibilityProvider = { AXIsProcessTrusted() },
        submitCredential: @escaping CredentialSubmitter = ConsoleUnlockCoordinator.submitCredentialWithCGEvent,
        promptCredential: @escaping CredentialPrompter = ConsoleUnlockCredentialPrompt.prompt,
        sleep: @escaping Sleeper = { Thread.sleep(forTimeInterval: $0) },
        now: @escaping Clock = Date.init,
        verificationTimeout: TimeInterval = 4,
        verificationInterval: TimeInterval = 0.1
    ) {
        self.gate = gate
        self.credentialVault = credentialVault
        self.recoveryCredentialStore = recoveryCredentialStore
        self.isLocked = isLocked
        self.loginwindow = loginwindow
        self.accessibilityTrusted = accessibilityTrusted
        self.submitCredential = submitCredential
        self.promptCredential = promptCredential
        self.sleep = sleep
        self.now = now
        self.verificationTimeout = verificationTimeout
        self.verificationInterval = verificationInterval
    }

    func execute(_ arguments: JSONValue) throws -> JSONValue {
        guard let object = arguments.objectValue else {
            throw PluginError.invalidArguments("console unlock requires an object argument")
        }
        let action = object["action"]?.stringValue ?? "unlock_console"
        let invocationId = try authorizedInvocationId(object)
        switch action {
        case "prepare_unlock_console":
            return try prepare(invocationId: invocationId)
        case "unlock_console":
            return try unlock(object: object, invocationId: invocationId)
        case "console_unlock_enroll":
            return try enrollRecovery(invocationId: invocationId)
        case "console_unlock_status":
            return try recoveryStatus(invocationId: invocationId)
        case "console_unlock_recover":
            return try recoverUnattended(invocationId: invocationId)
        case "console_unlock_revoke":
            return try revokeRecovery(invocationId: invocationId)
        default:
            throw PluginError(
                code: "COMPUTER_ACTION_UNSUPPORTED",
                message: "computer.console.unlock.v1 exposes temporary prepare/unlock plus unattended enroll/status/recover/revoke actions only.",
                retryable: false,
                domain: "computer"
            )
        }
    }

    private func prepare(invocationId: String) throws -> JSONValue {
        try gate.consumeAuthorization(invocationId: invocationId, at: now())
        guard !isLocked() else {
            throw PluginError(
                code: "CONSOLE_UNLOCK_PREPARE_REQUIRES_UNLOCKED_CONSOLE",
                message: "Prepare console unlock before locking the macOS console.",
                retryable: false,
                domain: "console"
            )
        }
        let credential = try promptCredential()
        let bounded = try boundedCredential(credential)
        let prepared = credentialVault.store(bounded, at: now())
        return .object([
            "prepared": .bool(true),
            "credential_handle": .string(prepared.handle),
            "expires_in_ms": .number(max(0, prepared.expiresAt.timeIntervalSince(now()) * 1_000)),
        ])
    }

    private func unlock(object: [String: JSONValue], invocationId: String) throws -> JSONValue {
        try gate.consumeAuthorization(invocationId: invocationId, at: now())

        guard isLocked() else {
            throw PluginError(
                code: "CONSOLE_UNLOCK_CONSOLE_NOT_LOCKED",
                message: "Console unlock is valid only while the current macOS console is actually locked.",
                retryable: false,
                domain: "console"
            )
        }
        guard accessibilityTrusted() else {
            throw PluginError(
                code: "CONSOLE_UNLOCK_ACCESSIBILITY_NOT_GRANTED",
                message: "Forge Desktop Operator must retain its own Accessibility permission before protected console input can be attempted.",
                retryable: false,
                domain: "tcc"
            )
        }
        guard let target = loginwindow() else {
            throw PluginError(
                code: "CONSOLE_UNLOCK_LOGINWINDOW_UNAVAILABLE",
                message: "The locked console does not expose the current protected macOS loginwindow surface.",
                retryable: false,
                domain: "console"
            )
        }
        guard isLocked(), loginwindow() == target else {
            throw PluginError(
                code: "CONSOLE_UNLOCK_STALE_LOGINWINDOW",
                message: "The protected lock-screen target changed before credential input; no input was performed.",
                retryable: false,
                domain: "console"
            )
        }

        let credential: String
        if let handle = object["credential_handle"]?.stringValue {
            credential = try credentialVault.consume(handle: handle, at: now())
        } else if let compatibilityCredential = object["credential"]?.stringValue {
            credential = try boundedCredential(compatibilityCredential)
        } else {
            throw PluginError(
                code: "CONSOLE_UNLOCK_CREDENTIAL_HANDLE_REQUIRED",
                message: "unlock_console requires one provider-local single-use credential handle.",
                retryable: false,
                domain: "authorization"
            )
        }

        return try performUnlock(credential: credential, expectedTarget: target)
    }

    private func performUnlock(
        credential: String,
        expectedTarget: ConsoleLoginwindowIdentity? = nil
    ) throws -> JSONValue {
        guard isLocked() else {
            throw PluginError(
                code: "CONSOLE_UNLOCK_CONSOLE_NOT_LOCKED",
                message: "Console unlock is valid only while the current macOS console is actually locked.",
                retryable: false,
                domain: "console"
            )
        }
        guard accessibilityTrusted() else {
            throw PluginError(
                code: "CONSOLE_UNLOCK_ACCESSIBILITY_NOT_GRANTED",
                message: "Forge Desktop Operator must retain its own Accessibility permission before protected console input can be attempted.",
                retryable: false,
                domain: "tcc"
            )
        }
        guard let target = expectedTarget ?? loginwindow() else {
            throw PluginError(
                code: "CONSOLE_UNLOCK_LOGINWINDOW_UNAVAILABLE",
                message: "The locked console does not expose the current protected macOS loginwindow surface.",
                retryable: false,
                domain: "console"
            )
        }
        guard isLocked(), loginwindow() == target else {
            throw PluginError(
                code: "CONSOLE_UNLOCK_STALE_LOGINWINDOW",
                message: "The protected lock-screen target changed before credential input; no input was performed.",
                retryable: false,
                domain: "console"
            )
        }

        try gate.consumeAttempt(at: now())
        try submitCredential(credential)

        let deadline = now().addingTimeInterval(verificationTimeout)
        while now() < deadline {
            if !isLocked() {
                return .object([
                    "unlocked": .bool(true),
                    "verified": .bool(true),
                    "postcondition": .string("console_unlocked"),
                ])
            }
            guard let current = loginwindow(), current == target else {
                throw PluginError(
                    code: "CONSOLE_UNLOCK_STALE_LOGINWINDOW",
                    message: "The protected loginwindow changed while the console remained locked; unlock could not be verified.",
                    retryable: false,
                    domain: "console"
                )
            }
            sleep(verificationInterval)
        }

        throw PluginError(
            code: "CONSOLE_UNLOCK_CREDENTIAL_NOT_ACCEPTED",
            message: "The provider-local credential submission completed but the authoritative console lock state did not change.",
            retryable: false,
            domain: "console"
        )
    }

    private func enrollRecovery(invocationId: String) throws -> JSONValue {
        try gate.consumeAuthorization(invocationId: invocationId, at: now())
        guard !isLocked() else {
            throw PluginError(
                code: "CONSOLE_UNLOCK_ENROLL_REQUIRES_UNLOCKED_CONSOLE",
                message: "Enable unattended console recovery while the macOS console is unlocked.",
                retryable: false,
                domain: "console"
            )
        }
        let credential = try boundedCredential(promptCredential())
        try recoveryCredentialStore.write(credential)
        return .object([
            "enrolled": .bool(true),
            "available": .bool(true),
            "persistence": .string("macos_keychain_device_only"),
        ])
    }

    private func recoveryStatus(invocationId: String) throws -> JSONValue {
        try gate.consumeAuthorization(invocationId: invocationId, at: now())
        let enrolled = try recoveryCredentialStore.isEnrolled()
        return .object([
            "enrolled": .bool(enrolled),
            "available": .bool(enrolled),
            "persistence": .string("macos_keychain_device_only"),
        ])
    }

    private func revokeRecovery(invocationId: String) throws -> JSONValue {
        try gate.consumeAuthorization(invocationId: invocationId, at: now())
        try recoveryCredentialStore.delete()
        return .object([
            "enrolled": .bool(false),
            "available": .bool(false),
            "revoked": .bool(true),
        ])
    }

    private func recoverUnattended(invocationId: String) throws -> JSONValue {
        try gate.consumeAuthorization(invocationId: invocationId, at: now())
        guard let credential = try recoveryCredentialStore.read() else {
            throw PluginError(
                code: "CONSOLE_UNLOCK_RECOVERY_NOT_ENROLLED",
                message: "Unattended console recovery is not enrolled on this Mac.",
                retryable: false,
                domain: "authorization"
            )
        }
        return try performUnlock(credential: try boundedCredential(credential))
    }

    private func authorizedInvocationId(_ object: [String: JSONValue]) throws -> String {
        guard let authorization = object["authorization"]?.objectValue,
              authorization["kind"]?.stringValue == "explicit_single_use",
              authorization["confirmed"]?.boolValue == true,
              let invocationId = authorization["invocation_id"]?.stringValue,
              UUID(uuidString: invocationId) != nil else {
            throw PluginError(
                code: "CONSOLE_UNLOCK_EXPLICIT_AUTHORIZATION_REQUIRED",
                message: "Console unlock requires one explicit single-use authorization for this invocation.",
                retryable: false,
                domain: "authorization"
            )
        }
        return invocationId
    }

    private func boundedCredential(_ credential: String) throws -> String {
        guard !credential.isEmpty, credential.lengthOfBytes(using: .utf8) <= 1_024 else {
            throw PluginError(
                code: "CONSOLE_UNLOCK_CREDENTIAL_REQUIRED",
                message: "Console unlock requires one bounded ephemeral credential input.",
                retryable: false,
                domain: "authorization"
            )
        }
        return credential
    }

    static func currentLoginwindow() -> ConsoleLoginwindowIdentity? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard (window[kCGWindowOwnerName as String] as? String) == "loginwindow",
                  let pidNumber = window[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            let pid = pid_t(pidNumber.int32Value)
            guard let application = NSRunningApplication(processIdentifier: pid),
                  application.bundleIdentifier == "com.apple.loginwindow" else { continue }
            return ConsoleLoginwindowIdentity(pid: pid, bundleIdentifier: "com.apple.loginwindow")
        }
        return nil
    }

    static func submitCredentialWithCGEvent(_ credential: String) throws {
        try InputDriver.typeUnicode(credential, replaceExisting: false)
        try InputDriver.press(keys: ["return"])
    }
}
