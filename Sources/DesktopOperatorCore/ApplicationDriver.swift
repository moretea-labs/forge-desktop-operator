import AppKit
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

    public static func activate(_ application: NSRunningApplication, timeoutSeconds: TimeInterval = 2) throws {
        guard !application.isTerminated, processIsAlive(application.processIdentifier) else {
            throw PluginError(code: "APP_ACTIVATION_FAILED", message: "Target application is no longer running", retryable: true, domain: "application")
        }
        guard application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) else {
            throw PluginError(code: "APP_ACTIVATION_FAILED", message: "macOS refused explicit application activation", retryable: true, domain: "application")
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if application.isActive { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        throw PluginError(code: "APP_ACTIVATION_TIMEOUT", message: "Target application did not become foreground after explicit activation", retryable: true, domain: "application")
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

    public static func isActive(pid: Int32) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
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
        NSWorkspace.shared.runningApplications.prefix(max(1, min(limit, 500))).map { app in
            .object([
                "pid": .number(Double(app.processIdentifier)),
                "name": app.localizedName.map(JSONValue.string) ?? .null,
                "bundle_id": app.bundleIdentifier.map(JSONValue.string) ?? .null,
                "active": .bool(app.isActive),
                "hidden": .bool(app.isHidden),
                "terminated": .bool(app.isTerminated)
            ])
        }
    }
}
