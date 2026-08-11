import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum ApplicationDriver {
    public static func findRunning(bundleIdentifier: String?, appName: String?) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            if let bundleIdentifier, app.bundleIdentifier == bundleIdentifier { return true }
            if let appName, app.localizedName?.caseInsensitiveCompare(appName) == .orderedSame { return true }
            return false
        }
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let bundleIdentifier {
            process.arguments = ["-b", bundleIdentifier]
        } else {
            process.arguments = ["-a", appName!]
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
        NSRunningApplication(processIdentifier: pid)?.isActive == true
    }

    private static func waitUntilActive(pid: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if isActive(pid: pid) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        return isActive(pid: pid)
    }

    private static func activateThroughAccessibility(pid: Int32) {
        let applicationElement = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(applicationElement, 0.35)
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(applicationElement, kAXFrontmostAttribute as CFString, &settable) == .success, settable.boolValue {
            _ = AXUIElementSetAttributeValue(applicationElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }

        var focusedWindow: CFTypeRef?
        if AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
           let window = focusedWindow {
            let axWindow = unsafeDowncast(window, to: AXUIElement.self)
            _ = AXUIElementSetMessagingTimeout(axWindow, 0.35)
            _ = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            return
        }

        var windowsValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(applicationElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
           let windows = windowsValue as? [AXUIElement],
           let window = windows.first {
            _ = AXUIElementSetMessagingTimeout(window, 0.35)
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
    }

    private static func activateThroughWindowClick(pid: Int32) -> Bool {
        guard let frame = windows(pid: pid).first(where: { $0.onScreen && $0.layer == 0 })?.frame,
              frame.width >= 80, frame.height >= 40 else { return false }
        let x = frame.x + frame.width / 2
        let y = frame.y + min(14, frame.height / 4)
        do {
            try InputDriver.click(x: x, y: y)
            return waitUntilActive(pid: pid, timeout: 0.45)
        } catch {
            return false
        }
    }

    @discardableResult
    public static func activate(pid: Int32) -> Bool {
        if isActive(pid: pid) { return true }
        activateThroughAccessibility(pid: pid)
        if waitUntilActive(pid: pid, timeout: 0.25) { return true }
        if activateThroughWindowClick(pid: pid) { return true }
        guard let application = NSRunningApplication(processIdentifier: pid),
              application.activate(options: [.activateIgnoringOtherApps]) else { return false }
        return waitUntilActive(pid: pid, timeout: 0.65)
    }

    public static func openURL(_ value: String) throws {
        guard let url = URL(string: value), url.scheme != nil else {
            throw PluginError.invalidArguments("desktop_open_url requires an absolute URL with a scheme")
        }
        guard NSWorkspace.shared.open(url) else {
            throw PluginError(code: "OPEN_URL_FAILED", message: "NSWorkspace could not open \(value)", retryable: true, domain: "application")
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
