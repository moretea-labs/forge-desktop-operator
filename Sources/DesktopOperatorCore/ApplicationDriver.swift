import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

struct ActivationDeadline: Sendable {
    private let startUptimeNanoseconds: UInt64
    private let uptimeDeadline: UInt64

    init(timeoutSeconds: TimeInterval) {
        let now = DispatchTime.now().uptimeNanoseconds
        startUptimeNanoseconds = now
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            uptimeDeadline = now
            return
        }
        let available = UInt64.max - now
        let nanoseconds = timeoutSeconds * 1_000_000_000
        uptimeDeadline = now + (nanoseconds >= Double(available) ? available : UInt64(nanoseconds))
    }

    private init(startUptimeNanoseconds: UInt64, uptimeDeadline: UInt64) {
        self.startUptimeNanoseconds = startUptimeNanoseconds
        self.uptimeDeadline = uptimeDeadline
    }

    var remainingSeconds: TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        guard uptimeDeadline > now else { return 0 }
        return Double(uptimeDeadline - now) / 1_000_000_000
    }

    var elapsedMilliseconds: Double {
        Double(DispatchTime.now().uptimeNanoseconds - startUptimeNanoseconds) / 1_000_000
    }

    func limited(to seconds: TimeInterval) -> ActivationDeadline {
        let now = DispatchTime.now().uptimeNanoseconds
        guard seconds.isFinite, seconds > 0 else {
            return ActivationDeadline(startUptimeNanoseconds: startUptimeNanoseconds, uptimeDeadline: now)
        }
        let available = UInt64.max - now
        let nanoseconds = seconds * 1_000_000_000
        let stageDeadline = now + (nanoseconds >= Double(available) ? available : UInt64(nanoseconds))
        return ActivationDeadline(startUptimeNanoseconds: startUptimeNanoseconds, uptimeDeadline: min(uptimeDeadline, stageDeadline))
    }
}

private final class ActivationOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = limit - data.count
        guard remaining > 0 else { return }
        data.append(contentsOf: chunk.prefix(remaining))
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

struct ActivationProcessOutput {
    let terminationStatus: Int32
    let stdout: String
    let stderr: String
}

public enum DesktopApplicationLaunchOwnership: String, Codable, Equatable, Sendable {
    case preexisting
    case providerLaunched = "provider_launched"
}

public struct ApplicationLaunchResult {
    public let application: NSRunningApplication
    public let ownership: DesktopApplicationLaunchOwnership
    public let ownedProcessIdentifier: Int32?
}

public enum ExactApplicationTerminationOutcome: String, Equatable, Sendable {
    case terminated
    case alreadyStopped = "already_stopped"
}

public enum ApplicationDriver {
    public static func findRunning(bundleIdentifier: String?, appName: String?) -> NSRunningApplication? {
        if let bundleIdentifier {
            let bundleMatches = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            if let running = preferredRunningApplication(bundleMatches) {
                return running
            }
        }

        let workspaceMatches = NSWorkspace.shared.runningApplications.filter { app in
            guard !app.isTerminated, processIsAlive(app.processIdentifier) else { return false }
            if let bundleIdentifier, app.bundleIdentifier == bundleIdentifier { return true }
            if let appName, app.localizedName?.caseInsensitiveCompare(appName) == .orderedSame { return true }
            return false
        }
        return preferredRunningApplication(workspaceMatches)
    }

    private static func preferredRunningApplication(_ applications: [NSRunningApplication]) -> NSRunningApplication? {
        applications
            .filter { !$0.isTerminated && processIsAlive($0.processIdentifier) }
            .sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive { return lhs.isActive }
                if lhs.isHidden != rhs.isHidden { return !lhs.isHidden }
                return lhs.processIdentifier > rhs.processIdentifier
            }
            .first
    }

    static func processIsAlive(_ pid: Int32) -> Bool {
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private final class SilentLaunchResult: @unchecked Sendable {
        let lock = NSLock()
        var application: NSRunningApplication?
        var error: Error?

        func store(application: NSRunningApplication?, error: Error?) {
            lock.lock()
            self.application = application
            self.error = error
            lock.unlock()
        }

        func snapshot() -> (NSRunningApplication?, Error?) {
            lock.lock()
            defer { lock.unlock() }
            return (application, error)
        }
    }

    private static func installedApplicationURL(bundleIdentifier: String?, appName: String?) -> URL? {
        if let bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url
        }
        guard let appName else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Applications/\(appName).app",
            "\(home)/Applications/\(appName).app",
            "/System/Applications/\(appName).app",
            "/System/Applications/Utilities/\(appName).app",
        ]
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    private static func launchSilently(applicationURL: URL, timeoutSeconds: TimeInterval = 8) throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false

        let result = SilentLaunchResult()
        let completed = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { application, error in
            result.store(application: application, error: error)
            completed.signal()
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if completed.wait(timeout: .now()) == .success {
                let (application, error) = result.snapshot()
                if let application { return application }
                throw PluginError(
                    code: "APP_LAUNCH_FAILED",
                    message: error?.localizedDescription ?? "NSWorkspace did not return a running application",
                    retryable: true,
                    domain: "application"
                )
            }
            if Thread.isMainThread {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        throw PluginError(code: "APP_LAUNCH_TIMEOUT", message: "Application did not appear in the GUI session", retryable: true, domain: "application")
    }

    private static func waitForSystemFrontmost(pid: Int32, deadline: ActivationDeadline) throws -> Bool {
        guard deadline.remainingSeconds > 0 else { return false }
        if try isActive(pid: pid, deadline: deadline) { return true }

        while deadline.remainingSeconds > 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(min(0.03, deadline.remainingSeconds)))
            guard deadline.remainingSeconds > 0 else { break }
            if try isActive(pid: pid, deadline: deadline) { return true }
        }
        return false
    }

    private static func requestWorkspaceActivation(
        _ application: NSRunningApplication,
        deadline: ActivationDeadline
    ) throws -> Bool {
        let arguments: [String]
        if let bundleIdentifier = application.bundleIdentifier, !bundleIdentifier.isEmpty {
            arguments = ["-b", bundleIdentifier]
        } else if let appName = application.localizedName, !appName.isEmpty {
            arguments = ["-a", appName]
        } else {
            return false
        }
        let output = try runBoundedProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/open"),
            arguments: arguments,
            deadline: deadline,
            stage: "workspace-open"
        )
        return output.terminationStatus == 0
    }

    private static func requestAccessibilityForeground(pid: Int32) -> AXError {
        let applicationElement = AXUIElementCreateApplication(pid)
        var bestResult = AXUIElementSetAttributeValue(
            applicationElement,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )

        var windowValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &windowValue) != .success
            || windowValue == nil {
            windowValue = nil
            _ = AXUIElementCopyAttributeValue(applicationElement, kAXMainWindowAttribute as CFString, &windowValue)
        }
        if windowValue == nil {
            var windowsValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(applicationElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
               let windows = windowsValue as? [AXUIElement],
               let firstWindow = windows.first {
                windowValue = firstWindow
            }
        }

        if let windowValue {
            let window = windowValue as! AXUIElement
            let focusedWindowResult = AXUIElementSetAttributeValue(
                applicationElement,
                kAXFocusedWindowAttribute as CFString,
                window
            )
            if bestResult != .success, focusedWindowResult == .success { bestResult = .success }

            let mainResult = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            if bestResult != .success, mainResult == .success { bestResult = .success }

            let focusedResult = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if bestResult != .success, focusedResult == .success { bestResult = .success }

            let raiseResult = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            if bestResult != .success, raiseResult == .success { bestResult = .success }
        }
        return bestResult
    }

    static func establishForegroundAuthority(
        pid: Int32,
        timeoutSeconds: TimeInterval,
        initialFrontmostCheck: (ActivationDeadline) throws -> Bool,
        appKitActivate: () -> Bool,
        workspaceActivate: (ActivationDeadline) throws -> Bool,
        accessibilityTrusted: () -> Bool,
        accessibilityActivate: () -> AXError,
        waitForFrontmost: (ActivationDeadline) throws -> Bool
    ) throws {
        let deadline = ActivationDeadline(timeoutSeconds: timeoutSeconds)
        var helperFailure: PluginError?
        let initialCheck = deadline.limited(to: min(0.2, deadline.remainingSeconds))
        do {
            if try initialFrontmostCheck(initialCheck) { return }
        } catch let error as PluginError {
            if error.code == "APP_ACTIVATION_HELPER_REAP_FAILED" { throw error }
            helperFailure = error
        }

        let appKitAccepted = deadline.remainingSeconds > 0 ? appKitActivate() : false
        let appKitBudget = min(max(timeoutSeconds * 0.2, 0.1), 0.4)
        if deadline.remainingSeconds > 0 {
            do {
                if try waitForFrontmost(deadline.limited(to: appKitBudget)) { return }
            } catch let error as PluginError {
                if error.code == "APP_ACTIVATION_HELPER_REAP_FAILED" { throw error }
                helperFailure = error
            }
        }

        let workspaceBudget = min(max(timeoutSeconds * 0.5, 0.25), 1.0)
        let workspaceDeadline = deadline.limited(to: workspaceBudget)
        var workspaceRequested = false
        if deadline.remainingSeconds > 0 {
            do {
                workspaceRequested = try workspaceActivate(workspaceDeadline)
            } catch let error as PluginError {
                if error.code == "APP_ACTIVATION_HELPER_REAP_FAILED" { throw error }
                helperFailure = error
            }
        }
        if workspaceRequested && deadline.remainingSeconds > 0 {
            do {
                if try waitForFrontmost(workspaceDeadline) { return }
            } catch let error as PluginError {
                if error.code == "APP_ACTIVATION_HELPER_REAP_FAILED" { throw error }
                helperFailure = error
            }
        }

        var accessibilityResult: AXError?
        if deadline.remainingSeconds > 0, accessibilityTrusted() {
            accessibilityResult = accessibilityActivate()
            if accessibilityResult == .success, deadline.remainingSeconds > 0 {
                do {
                    if try waitForFrontmost(deadline) { return }
                } catch let error as PluginError {
                    if error.code == "APP_ACTIVATION_HELPER_REAP_FAILED" { throw error }
                    helperFailure = error
                }
            }
        }

        if let helperFailure { throw helperFailure }
        if !appKitAccepted && !workspaceRequested && accessibilityResult != .success {
            throw PluginError(
                code: "APP_ACTIVATION_FAILED",
                message: accessibilityResult == nil
                    ? "macOS refused explicit application activation and no trusted foreground fallback was available"
                    : "macOS refused explicit application activation and Accessibility foreground fallback failed with code \(accessibilityResult!.rawValue)",
                retryable: true,
                domain: "application"
            )
        }
        throw PluginError(
            code: "APP_ACTIVATION_TIMEOUT",
            message: accessibilityResult == nil
                ? "Target application did not become system foreground before the shared activation deadline"
                : "Target application did not become system foreground after AppKit, Workspace, and Accessibility activation requests",
            retryable: true,
            domain: "application",
            details: .object([
                "stage": .string("foreground-verification"),
                "elapsed_ms": .number(deadline.elapsedMilliseconds)
            ])
        )
    }

    static func sessionIsLocked(_ dictionary: CFDictionary?) -> Bool {
        guard let dictionary else { return false }
        let values = dictionary as NSDictionary
        return (values["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    static func currentSessionIsLocked() -> Bool {
        sessionIsLocked(CGSessionCopyCurrentDictionary())
    }

    public static func activate(_ application: NSRunningApplication, timeoutSeconds: TimeInterval = 5) throws {
        guard !application.isTerminated, processIsAlive(application.processIdentifier) else {
            throw PluginError(code: "APP_ACTIVATION_FAILED", message: "Target application is no longer running", retryable: true, domain: "application")
        }
        if currentSessionIsLocked() {
            throw PluginError(
                code: "APP_ACTIVATION_UNAVAILABLE_CONSOLE_LOCKED",
                message: "The macOS GUI console is locked; no ordinary application can become system foreground until the user session is unlocked",
                retryable: true,
                domain: "application"
            )
        }
        let pid = application.processIdentifier
        try establishForegroundAuthority(
            pid: pid,
            timeoutSeconds: timeoutSeconds,
            initialFrontmostCheck: { try isActive(pid: pid, deadline: $0) },
            appKitActivate: {
                application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            },
            workspaceActivate: { try requestWorkspaceActivation(application, deadline: $0) },
            accessibilityTrusted: { AXIsProcessTrusted() },
            accessibilityActivate: { requestAccessibilityForeground(pid: pid) },
            waitForFrontmost: { try waitForSystemFrontmost(pid: pid, deadline: $0) }
        )
    }

    public static func ensureRunningWithProvenance(
        bundleIdentifier: String?,
        appName: String?,
        launch: Bool,
        exactProcessIdentifier: Int32? = nil,
        exactBundlePath: String? = nil
    ) throws -> ApplicationLaunchResult {
        if let exactProcessIdentifier {
            guard exactProcessIdentifier > 0, !launch else {
                throw PluginError.invalidArguments("Exact process selection requires a positive process_id and launch=false")
            }
            guard let application = NSRunningApplication(processIdentifier: exactProcessIdentifier),
                  !application.isTerminated, processIsAlive(exactProcessIdentifier) else {
                throw PluginError(code: "APP_PROCESS_NOT_RUNNING", message: "The exact requested application process is not running", retryable: false, domain: "application")
            }
            if let bundleIdentifier, application.bundleIdentifier != bundleIdentifier {
                throw PluginError(code: "APP_PROCESS_IDENTITY_MISMATCH", message: "The requested process has a different bundle identity", retryable: false, domain: "application")
            }
            if let appName, application.localizedName?.caseInsensitiveCompare(appName) != .orderedSame {
                throw PluginError(code: "APP_PROCESS_IDENTITY_MISMATCH", message: "The requested process has a different application name", retryable: false, domain: "application")
            }
            if let exactBundlePath {
                guard exactBundlePath.hasPrefix("/"),
                      let actualURL = application.bundleURL,
                      actualURL.standardizedFileURL.resolvingSymlinksInPath().path
                        == URL(fileURLWithPath: exactBundlePath).standardizedFileURL.resolvingSymlinksInPath().path else {
                    throw PluginError(code: "APP_BUNDLE_PATH_MISMATCH", message: "The requested process is not running from the exact application bundle path", retryable: false, domain: "application")
                }
            }
            return ApplicationLaunchResult(application: application, ownership: .preexisting, ownedProcessIdentifier: nil)
        }
        guard exactBundlePath == nil else {
            throw PluginError.invalidArguments("bundle_path requires exact process_id")
        }
        if let running = findRunning(bundleIdentifier: bundleIdentifier, appName: appName) {
            return ApplicationLaunchResult(application: running, ownership: .preexisting, ownedProcessIdentifier: nil)
        }
        guard launch else {
            throw PluginError(code: "APP_NOT_RUNNING", message: "Target application is not running", retryable: true, domain: "application")
        }
        guard bundleIdentifier != nil || appName != nil else {
            throw PluginError.invalidArguments("desktop_session_open requires bundle_id or app_name")
        }

        // Launch through NSWorkspace instead of `open -g` whenever the app bundle
        // can be resolved. Electron apps such as Figma may otherwise leave a Unix
        // process without registering a usable GUI application. `activates=false`
        // preserves the Desktop Operator invariant that automation never steals
        // foreground focus.
        if let applicationURL = installedApplicationURL(bundleIdentifier: bundleIdentifier, appName: appName) {
            let application = try launchSilently(applicationURL: applicationURL)
            return ApplicationLaunchResult(application: application, ownership: .providerLaunched, ownedProcessIdentifier: application.processIdentifier)
        }

        // Keep the previous generic fallback for applications that are discoverable
        // by LaunchServices name but do not live in one of the bounded app roots.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let bundleIdentifier {
            process.arguments = ["-g", "-b", bundleIdentifier]
        } else {
            process.arguments = ["-g", "-a", appName!]
        }
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw PluginError(code: "APP_LAUNCH_FAILED", message: error.localizedDescription, retryable: true, domain: "application")
        }
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PluginError(code: "APP_LAUNCH_FAILED", message: message ?? "open exited with status \(process.terminationStatus)", retryable: true, domain: "application")
        }

        let deadline = Date().addingTimeInterval(8)
        repeat {
            if let running = findRunning(bundleIdentifier: bundleIdentifier, appName: appName) {
                return ApplicationLaunchResult(application: running, ownership: .providerLaunched, ownedProcessIdentifier: running.processIdentifier)
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline

        throw PluginError(code: "APP_LAUNCH_TIMEOUT", message: "Application did not appear in the GUI session", retryable: true, domain: "application")
    }

    public static func ensureRunning(bundleIdentifier: String?, appName: String?, launch: Bool) throws -> NSRunningApplication {
        try ensureRunningWithProvenance(bundleIdentifier: bundleIdentifier, appName: appName, launch: launch).application
    }

    public static func terminateExact(
        pid: Int32,
        bundleIdentifier: String?,
        appName: String?,
        timeoutSeconds: TimeInterval = 2
    ) throws -> ExactApplicationTerminationOutcome {
        guard processIsAlive(pid) else { return .alreadyStopped }
        guard let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated else {
            return .alreadyStopped
        }
        if let bundleIdentifier, application.bundleIdentifier != bundleIdentifier {
            throw PluginError(code: "APP_TERMINATION_IDENTITY_MISMATCH", message: "Exact termination pid no longer belongs to the authorized application bundle", retryable: false, domain: "application")
        }
        if bundleIdentifier == nil, let appName,
           application.localizedName?.caseInsensitiveCompare(appName) != .orderedSame {
            throw PluginError(code: "APP_TERMINATION_IDENTITY_MISMATCH", message: "Exact termination pid no longer belongs to the authorized application name", retryable: false, domain: "application")
        }
        guard application.terminate() else {
            throw PluginError(code: "APP_TERMINATION_REJECTED", message: "macOS rejected the exact application termination request", retryable: true, domain: "application")
        }
        let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
        while Date() < deadline {
            if !processIsAlive(pid) || application.isTerminated { return .terminated }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        guard !processIsAlive(pid) || application.isTerminated else {
            throw PluginError(code: "APP_TERMINATION_TIMEOUT", message: "The exact application process remained alive after a graceful termination request", retryable: true, domain: "application")
        }
        return .terminated
    }

    static func parseLaunchServicesFrontmostPID(_ output: String) -> Int32? {
        guard let marker = output.range(of: "pid =") else { return nil }
        let suffix = output[marker.upperBound...]
        guard let token = suffix.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        return Int32(token)
    }

    static func runBoundedProcess(
        executableURL: URL,
        arguments: [String],
        deadline: ActivationDeadline,
        stage: String,
        maxOutputBytes: Int = 8_192
    ) throws -> ActivationProcessOutput {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        func elapsedMilliseconds() -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        }
        func errorDetails(helperPID: Int32? = nil, helperReaped: Bool? = nil) -> JSONValue {
            var values: [String: JSONValue] = [
                "stage": .string(stage),
                "elapsed_ms": .number(elapsedMilliseconds()),
                "activation_elapsed_ms": .number(deadline.elapsedMilliseconds)
            ]
            if let helperPID { values["helper_pid"] = .number(Double(helperPID)) }
            if let helperReaped { values["helper_reaped"] = .bool(helperReaped) }
            return .object(values)
        }

        guard deadline.remainingSeconds > 0 else {
            throw PluginError(
                code: "APP_ACTIVATION_HELPER_TIMEOUT",
                message: "Activation helper \(stage) had no remaining foreground deadline budget",
                retryable: true,
                domain: "application",
                details: errorDetails()
            )
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutBuffer = ActivationOutputBuffer(limit: maxOutputBytes)
        let stderrBuffer = ActivationOutputBuffer(limit: maxOutputBytes)
        let outputDrained = DispatchGroup()
        let terminated = DispatchSemaphore(value: 0)

        func installReader(_ pipe: Pipe, buffer: ActivationOutputBuffer) {
            outputDrained.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    outputDrained.leave()
                } else {
                    buffer.append(data)
                }
            }
        }

        func closePipes() {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
        }

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        installReader(stdoutPipe, buffer: stdoutBuffer)
        installReader(stderrPipe, buffer: stderrBuffer)
        process.terminationHandler = { _ in terminated.signal() }

        do {
            try process.run()
        } catch {
            closePipes()
            throw PluginError(
                code: "APP_ACTIVATION_HELPER_LAUNCH_FAILED",
                message: "Activation helper \(stage) could not start: \(error.localizedDescription)",
                retryable: true,
                domain: "application",
                details: errorDetails()
            )
        }

        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        if terminated.wait(timeout: .now() + deadline.remainingSeconds) == .timedOut {
            let helperPID = process.processIdentifier
            if process.isRunning {
                process.terminate()
            }
            let reaped = terminated.wait(timeout: .now() + .milliseconds(200)) == .success || !process.isRunning
            closePipes()
            throw PluginError(
                code: reaped ? "APP_ACTIVATION_HELPER_TIMEOUT" : "APP_ACTIVATION_HELPER_REAP_FAILED",
                message: reaped
                    ? "Activation helper \(stage) exceeded its shared foreground deadline and its exact child process was reaped"
                    : "Activation helper \(stage) exceeded its deadline but its exact child did not exit within the cleanup grace",
                retryable: true,
                domain: "application",
                details: errorDetails(helperPID: helperPID, helperReaped: reaped)
            )
        }

        _ = outputDrained.wait(timeout: .now() + .milliseconds(25))
        closePipes()
        return ActivationProcessOutput(
            terminationStatus: process.terminationStatus,
            stdout: String(data: stdoutBuffer.snapshot(), encoding: .utf8) ?? "",
            stderr: String(data: stderrBuffer.snapshot(), encoding: .utf8) ?? ""
        )
    }

    private static func runLaunchServicesInfo(
        _ arguments: [String],
        deadline: ActivationDeadline,
        stage: String
    ) throws -> String? {
        let output = try runBoundedProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/lsappinfo"),
            arguments: arguments,
            deadline: deadline,
            stage: stage
        )
        guard output.terminationStatus == 0 else { return nil }
        return output.stdout
    }

    static func launchServicesFrontmostPID(
        deadline: ActivationDeadline,
        runHelper: ([String], ActivationDeadline, String) throws -> String?
    ) throws -> Int32? {
        guard let front = try runHelper(["front"], deadline, "launchservices-front")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            front.hasPrefix("ASN:"),
            let info = try runHelper(["info", "-only", "pid", front], deadline, "launchservices-info")
        else { return nil }
        return parseLaunchServicesFrontmostPID(info)
    }

    private static func launchServicesFrontmostPID(deadline: ActivationDeadline) throws -> Int32? {
        try launchServicesFrontmostPID(deadline: deadline) { arguments, deadline, stage in
            try runLaunchServicesInfo(arguments, deadline: deadline, stage: stage)
        }
    }

    static func foregroundMatches(pid: Int32, frontmostPID: Int32?) -> Bool {
        frontmostPID == pid
    }

    static func isActive(pid: Int32, deadline: ActivationDeadline) throws -> Bool {
        foregroundMatches(pid: pid, frontmostPID: try launchServicesFrontmostPID(deadline: deadline))
    }

    public static func isActive(pid: Int32) -> Bool {
        do {
            return try isActive(pid: pid, deadline: ActivationDeadline(timeoutSeconds: 0.5))
        } catch {
            return false
        }
    }

    public static func openURL(_ value: String) throws {
        guard let url = URL(string: value), url.scheme != nil else {
            throw PluginError.invalidArguments("desktop_open_url requires an absolute URL with a scheme")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", url.absoluteString]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw PluginError(code: "OPEN_URL_FAILED", message: error.localizedDescription, retryable: true, domain: "application")
        }
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PluginError(code: "OPEN_URL_FAILED", message: message ?? "open exited with status \(process.terminationStatus)", retryable: true, domain: "application")
        }
    }

    public static func windows(pid: Int32? = nil) -> [DesktopWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return raw.compactMap { item in
            let ownerPid = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            if let pid, ownerPid != pid { return nil }
            guard let number = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
            let bounds: DesktopFrame?
            if let dictionary = item[kCGWindowBounds as String] as? NSDictionary,
               let rect = CGRect(dictionaryRepresentation: dictionary) {
                bounds = DesktopFrame(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
            } else {
                bounds = nil
            }
            return DesktopWindow(
                windowId: number,
                pid: ownerPid,
                ownerName: item[kCGWindowOwnerName as String] as? String ?? "Unknown",
                title: item[kCGWindowName as String] as? String,
                layer: (item[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                alpha: (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                onScreen: (item[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true,
                frame: bounds
            )
        }
    }

    static var frontmostProcessIdentifier: Int32? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// Resolves an observed AX window only when its exact CGWindow is the system-frontmost app window.
    /// CGWindowListCopyWindowInfo preserves front-to-back ordering; ambiguous geometry fails closed.
    static func resolveExactFrontmostWindowId(
        pid: Int32,
        windowFrame: DesktopFrame,
        frontmostPID: Int32?,
        windows: [DesktopWindow]
    ) throws -> UInt32 {
        let values = [windowFrame.x, windowFrame.y, windowFrame.width, windowFrame.height]
        guard values.allSatisfy({ $0.isFinite }), windowFrame.width >= 1, windowFrame.height >= 1 else {
            throw PluginError(
                code: "COMPUTER_ELEMENT_CLICK_WINDOW_BOUNDS_INVALID",
                message: "The observed AX window has invalid bounds.",
                retryable: true,
                domain: "input"
            )
        }
        guard frontmostPID == pid else {
            throw PluginError(
                code: "COMPUTER_ELEMENT_CLICK_APP_NOT_FRONTMOST",
                message: "Click is allowed only while the exact observed application is already system-frontmost; no activation is attempted.",
                retryable: true,
                domain: "input"
            )
        }

        let visibleAppWindows = windows.filter {
            $0.onScreen && $0.layer == 0 && $0.alpha.isFinite && $0.alpha > 0 && $0.frame != nil
        }
        guard let frontmost = visibleAppWindows.first else {
            throw PluginError(
                code: "COMPUTER_ELEMENT_CLICK_WINDOW_UNAVAILABLE",
                message: "No visible application window can be verified for the observed target.",
                retryable: true,
                domain: "input"
            )
        }
        guard frontmost.pid == pid, frontmost.frame == windowFrame else {
            throw PluginError(
                code: "COMPUTER_ELEMENT_CLICK_WINDOW_NOT_FRONTMOST",
                message: "The exact AX window from the observation is not the system-frontmost application window.",
                retryable: true,
                domain: "input"
            )
        }

        let matches = visibleAppWindows.filter { $0.pid == pid && $0.frame == windowFrame }
        guard matches.count == 1, let exact = matches.first, exact.windowId == frontmost.windowId else {
            throw PluginError(
                code: "COMPUTER_ELEMENT_CLICK_WINDOW_AMBIGUOUS",
                message: "The observed AX bounds do not resolve to one exact frontmost system window.",
                retryable: true,
                domain: "input"
            )
        }
        return exact.windowId
    }

    public static func runningApplicationSummaries(limit: Int = 100) -> [JSONValue] {
        let frontmostPID: Int32?
        do {
            frontmostPID = try launchServicesFrontmostPID(deadline: ActivationDeadline(timeoutSeconds: 0.5))
        } catch {
            frontmostPID = nil
        }
        return NSWorkspace.shared.runningApplications.prefix(max(1, min(limit, 500))).map { app in
            .object([
                "pid": .number(Double(app.processIdentifier)),
                "name": app.localizedName.map(JSONValue.string) ?? .null,
                "bundle_id": app.bundleIdentifier.map(JSONValue.string) ?? .null,
                "active": .bool(foregroundMatches(pid: app.processIdentifier, frontmostPID: frontmostPID)),
                "hidden": .bool(app.isHidden),
                "terminated": .bool(app.isTerminated)
            ])
        }
    }
}
