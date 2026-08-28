import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

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

    private static func waitForSystemFrontmost(pid: Int32, timeoutSeconds: TimeInterval) -> Bool {
        if isActive(pid: pid) { return true }
        let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            if isActive(pid: pid) { return true }
        }
        return isActive(pid: pid)
    }

    private static func requestWorkspaceActivation(_ application: NSRunningApplication) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let bundleIdentifier = application.bundleIdentifier, !bundleIdentifier.isEmpty {
            process.arguments = ["-b", bundleIdentifier]
        } else if let appName = application.localizedName, !appName.isEmpty {
            process.arguments = ["-a", appName]
        } else {
            return false
        }
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        return process.terminationStatus == 0
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
        appKitActivate: () -> Bool,
        workspaceActivate: () -> Bool,
        accessibilityTrusted: () -> Bool,
        accessibilityActivate: () -> AXError,
        waitForFrontmost: (TimeInterval) -> Bool
    ) throws {
        if waitForFrontmost(0) { return }

        let appKitAccepted = appKitActivate()
        let appKitBudget = min(max(timeoutSeconds * 0.2, 0.1), 0.4)
        if waitForFrontmost(appKitBudget) { return }

        let workspaceRequested = workspaceActivate()
        let workspaceBudget = min(max(timeoutSeconds * 0.5, 0.25), 1.0)
        if workspaceRequested && waitForFrontmost(workspaceBudget) { return }

        var accessibilityResult: AXError?
        if accessibilityTrusted() {
            accessibilityResult = accessibilityActivate()
            if accessibilityResult == .success,
               waitForFrontmost(max(0, timeoutSeconds - appKitBudget - workspaceBudget)) {
                return
            }
        }

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
                ? "Target application did not become system foreground after AppKit and Workspace activation requests"
                : "Target application did not become system foreground after AppKit, Workspace, and Accessibility activation requests",
            retryable: true,
            domain: "application"
        )
    }

    static func sessionIsLocked(_ dictionary: CFDictionary?) -> Bool {
        guard let dictionary else { return false }
        let values = dictionary as NSDictionary
        return (values["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    private static func currentSessionIsLocked() -> Bool {
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
            appKitActivate: {
                application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            },
            workspaceActivate: { requestWorkspaceActivation(application) },
            accessibilityTrusted: { AXIsProcessTrusted() },
            accessibilityActivate: { requestAccessibilityForeground(pid: pid) },
            waitForFrontmost: { waitForSystemFrontmost(pid: pid, timeoutSeconds: $0) }
        )
    }

    public static func ensureRunning(bundleIdentifier: String?, appName: String?, launch: Bool) throws -> NSRunningApplication {
        if let running = findRunning(bundleIdentifier: bundleIdentifier, appName: appName) {
            return running
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
            return try launchSilently(applicationURL: applicationURL)
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
                return running
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline

        throw PluginError(code: "APP_LAUNCH_TIMEOUT", message: "Application did not appear in the GUI session", retryable: true, domain: "application")
    }

    static func parseLaunchServicesFrontmostPID(_ output: String) -> Int32? {
        guard let marker = output.range(of: "pid =") else { return nil }
        let suffix = output[marker.upperBound...]
        guard let token = suffix.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        return Int32(token)
    }

    private static func runLaunchServicesInfo(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private static func launchServicesFrontmostPID() -> Int32? {
        guard let front = runLaunchServicesInfo(["front"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              front.hasPrefix("ASN:"),
              let info = runLaunchServicesInfo(["info", "-only", "pid", front])
        else { return nil }
        return parseLaunchServicesFrontmostPID(info)
    }

    static func foregroundMatches(pid: Int32, frontmostPID: Int32?) -> Bool {
        frontmostPID == pid
    }

    public static func isActive(pid: Int32) -> Bool {
        foregroundMatches(pid: pid, frontmostPID: launchServicesFrontmostPID())
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

    public static func runningApplicationSummaries(limit: Int = 100) -> [JSONValue] {
        let frontmostPID = launchServicesFrontmostPID()
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
