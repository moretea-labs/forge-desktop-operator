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

    func consume(invocationId: String, at now: Date) throws {
        lock.lock()
        defer { lock.unlock() }

        consumedInvocations = consumedInvocations.filter { now.timeIntervalSince($0.value) <= replayRetention }
        attempts.removeAll { now.timeIntervalSince($0) > attemptWindow }

        guard consumedInvocations[invocationId] == nil else {
            throw PluginError(
                code: "CONSOLE_UNLOCK_AUTHORIZATION_REPLAYED",
                message: "This explicit console-unlock authorization has already been consumed.",
                retryable: false,
                domain: "authorization"
            )
        }
        consumedInvocations[invocationId] = now

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
    typealias Sleeper = (_ seconds: TimeInterval) -> Void
    typealias Clock = () -> Date

    private let gate: ConsoleUnlockAttemptGate
    private let isLocked: LockedProvider
    private let loginwindow: LoginwindowProvider
    private let accessibilityTrusted: AccessibilityProvider
    private let submitCredential: CredentialSubmitter
    private let sleep: Sleeper
    private let now: Clock
    private let verificationTimeout: TimeInterval
    private let verificationInterval: TimeInterval

    init(
        gate: ConsoleUnlockAttemptGate = ConsoleUnlockAttemptGate(),
        isLocked: @escaping LockedProvider = ApplicationDriver.currentSessionIsLocked,
        loginwindow: @escaping LoginwindowProvider = ConsoleUnlockCoordinator.currentLoginwindow,
        accessibilityTrusted: @escaping AccessibilityProvider = { AXIsProcessTrusted() },
        submitCredential: @escaping CredentialSubmitter = ConsoleUnlockCoordinator.submitCredentialWithCGEvent,
        sleep: @escaping Sleeper = { Thread.sleep(forTimeInterval: $0) },
        now: @escaping Clock = Date.init,
        verificationTimeout: TimeInterval = 4,
        verificationInterval: TimeInterval = 0.1
    ) {
        self.gate = gate
        self.isLocked = isLocked
        self.loginwindow = loginwindow
        self.accessibilityTrusted = accessibilityTrusted
        self.submitCredential = submitCredential
        self.sleep = sleep
        self.now = now
        self.verificationTimeout = verificationTimeout
        self.verificationInterval = verificationInterval
    }

    func execute(_ arguments: JSONValue) throws -> JSONValue {
        guard let object = arguments.objectValue else {
            throw PluginError.invalidArguments("unlock_console requires an object argument")
        }
        guard let authorization = object["authorization"]?.objectValue,
              authorization["kind"]?.stringValue == "explicit_single_use",
              authorization["confirmed"]?.boolValue == true,
              let invocationId = authorization["invocation_id"]?.stringValue,
              UUID(uuidString: invocationId) != nil else {
            throw PluginError(
                code: "CONSOLE_UNLOCK_EXPLICIT_AUTHORIZATION_REQUIRED",
                message: "unlock_console requires one explicit single-use authorization for this invocation.",
                retryable: false,
                domain: "authorization"
            )
        }
        guard let credential = object["credential"]?.stringValue,
              !credential.isEmpty,
              credential.lengthOfBytes(using: .utf8) <= 1_024 else {
            throw PluginError(
                code: "CONSOLE_UNLOCK_CREDENTIAL_REQUIRED",
                message: "unlock_console requires one bounded ephemeral credential input.",
                retryable: false,
                domain: "authorization"
            )
        }

        try gate.consume(invocationId: invocationId, at: now())

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

        // Re-read both system facts immediately before physical input. This capability never
        // treats loginwindow as a normal desktop application and never falls back to coordinates.
        guard isLocked(), loginwindow() == target else {
            throw PluginError(
                code: "CONSOLE_UNLOCK_STALE_LOGINWINDOW",
                message: "The protected lock-screen target changed before credential input; no input was performed.",
                retryable: false,
                domain: "console"
            )
        }

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
            message: "The credential submission completed but the authoritative console lock state did not change. The credential may have been rejected or protected loginwindow input may have been isolated by macOS.",
            retryable: false,
            domain: "console"
        )
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
        // The only physical-input sequence owned by this capability is credential text + Return.
        // There is intentionally no pointer input, application activation, shell/AppleScript path,
        // clipboard path, or generic key forwarding here.
        try InputDriver.typeUnicode(credential, replaceExisting: false)
        try InputDriver.press(keys: ["return"])
    }
}
