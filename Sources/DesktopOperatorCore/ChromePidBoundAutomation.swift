import AppKit
import Foundation
import ScriptingBridge
import ChromeScriptingGlue

/// The sole production Chrome Apple Events transport. ScriptingBridge's
/// processIdentifier binds every event to the verified GUI process rather
/// than asking LaunchServices to resolve the ambiguous app name.
enum ChromePidBoundAutomation {
    private final class FailureRecorder: NSObject, SBApplicationDelegate {
        var lastError: Error?
        func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: Error) -> Any? {
            lastError = error
            return nil
        }
    }

    private static let record = String(UnicodeScalar(30)!)
    private static let field = String(UnicodeScalar(31)!)
    private static let maxWindows = 128
    private static let maxTabs = 500

    // Apple Event callbacks can arrive after an action was attempted. Even a
    // failed call may have changed a tab; never mark its outcome safe to replay.
    static func eventFailure(_ error: Error, action: String) -> PluginError {
        let code = (action == "metadata" || action == "list_tabs")
            ? "BROWSER_AUTOMATION_NATIVE_EVENT_FAILED"
            : "BROWSER_AUTOMATION_MUTATION_OUTCOME_UNKNOWN"
        return PluginError(
            code: code,
            message: "Process-bound Chrome Apple Event failed: " +
                String(error.localizedDescription.prefix(1_000)),
            retryable: false,
            domain: "browser"
        )
    }


    private static func code(_ four: String) -> UInt32 {
        precondition(four.utf8.count == 4)
        return four.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func value(_ object: SBObject, _ key: String) -> Any? {
        object.property(withCode: code(key)).get()
    }
    private static func text(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }
    private static func propertyText(_ object: SBObject, _ key: String) -> String {
        text(value(object, key))
    }
    private static func windows(_ app: SBApplication) -> [SBObject] {
        Array(app.elementArray(withCode: code("cwin")).prefix(maxWindows)).compactMap { $0 as? SBObject }
    }
    private static func tabs(_ window: SBObject) -> [SBObject] {
        Array(window.elementArray(withCode: code("CrTb")).prefix(maxTabs)).compactMap { $0 as? SBObject }
    }

    private static func boundedField(_ field: String) -> String {
        field.replacingOccurrences(of: record, with: "")
             .replacingOccurrences(of: self.field, with: "")
    }
    private static func activeTab(_ window: SBObject) throws -> SBObject {
        guard let tab = window.property(withCode: code("acTa")).get() as? SBObject else {
            throw error("BROWSER_AUTOMATION_TAB_NOT_FOUND", "Chrome has no active tab")
        }
        return tab
    }
    private static func exactTab(_ windows: [SBObject], windowId: String, tabId: String) throws -> (SBObject, SBObject) {
        let matches = windows.flatMap { window -> [(SBObject, SBObject)] in
            tabs(window).filter { propertyText($0, "ID  ") == tabId }.map { (window, $0) }
        }
        guard matches.count == 1 else {
            throw error("BROWSER_AUTOMATION_TAB_NOT_FOUND", "Chrome tab identity is absent or ambiguous")
        }
        // A moved tab keeps its tabId. A stale window hint does not silently
        // resolve to a different tab; unique exact tabId is the authority.
        _ = windowId
        return matches[0]
    }
    private static func error(_ code: String, _ message: String) -> PluginError {
        PluginError(code: code, message: message, retryable: false, domain: "browser")
    }
    private static func checkedApp(pid: pid_t, timeoutMs: Int) throws -> ForgeChromeApplication {
        guard let running = NSRunningApplication(processIdentifier: pid),
              running.bundleIdentifier == "com.google.Chrome",
              running.executableURL?.path.hasSuffix("/Google Chrome.app/Contents/MacOS/Google Chrome") == true,
              let app = ForgeChromeApplication(processIdentifier: pid), app.isRunning else {
            throw error("BROWSER_AUTOMATION_PROCESS_IDENTITY_LOST",
                        "Verified GUI Chrome PID is no longer the same scriptable application")
        }
        // ScriptingBridge timeout uses seconds. Never permit unbounded calls.
        app.timeout = max(1, (timeoutMs + 999) / 1_000)
        return app
    }

    static func execute(
        pid: pid_t, action: String, windowId: String?, tabId: String?,
        url: String?, javascript: String?, timeoutMs: Int,
        frontmostPID: pid_t?
    ) throws -> String {
        let app = try checkedApp(pid: pid, timeoutMs: timeoutMs)
        let failures = FailureRecorder()
        app.delegate = failures
        defer { app.delegate = nil }
        let result: String
        do {
          result = try { () throws -> String in
        let allWindows = windows(app)
        func selected() throws -> (SBObject, SBObject) {
            if let tabId, !tabId.isEmpty {
                return try exactTab(allWindows, windowId: windowId ?? "", tabId: tabId)
            }
            guard action == "metadata" || action == "list_tabs" else {
                throw error("BROWSER_AUTOMATION_TAB_REF_REQUIRED", "A Chrome mutation requires an exact bound tab")
            }
            guard let window = allWindows.first else {
                throw error("BROWSER_AUTOMATION_NO_WINDOW", "Chrome has no scriptable GUI window")
            }
            return (window, try activeTab(window))
        }
        switch action {
        case "metadata":
            let (window, tab) = try selected()
            let bounds = (value(window, "pbnd") as? NSValue)?.rectValue ?? .zero
            // Trusted input must never be authorized by an active tab in a
            // background Chrome window merely because the app is foreground.
            let frontmost = frontmostPID == pid && propertyText(window, "pidx") == "1"
            let active = propertyText(try activeTab(window), "ID  ") == propertyText(tab, "ID  ")
            return [
                String(frontmost), boundedField(propertyText(tab, "URL ")),
                tabId == nil ? boundedField(propertyText(tab, "pnam")) : "",
                String(Int(bounds.minX)), String(Int(bounds.minY)),
                String(Int(bounds.maxX)), String(Int(bounds.maxY)),
                propertyText(window, "ID  "), propertyText(tab, "ID  "),
                String(active), String(text(value(tab, "ldng")) == "1"),
            ].joined(separator: record)
        case "list_tabs":
            var entries: [String] = []
            var truncated = false
            for window in allWindows {
                let activeID = propertyText(try activeTab(window), "ID  ")
                for tab in tabs(window) {
                    if entries.count == maxTabs { truncated = true; break }
                    entries.append([
                        propertyText(window, "ID  "),
                        propertyText(tab, "ID  "),
                        String(propertyText(tab, "ID  ") == activeID),
                        boundedField(propertyText(tab, "URL ")),
                        boundedField(propertyText(tab, "pnam")),
                    ].joined(separator: field))
                }
                if truncated { break }
            }
            return ([String(truncated)] + entries).joined(separator: record)
        case "create_tab":
            guard let url, !url.isEmpty, let window = allWindows.first else {
                throw error("BROWSER_AUTOMATION_CREATE_TAB_INVALID", "Chrome tab creation needs a URL and an existing window")
            }
            let previousActiveID = propertyText(try activeTab(window), "ID  ")
            let previous = Set(tabs(window).map { propertyText($0, "ID  ") })
            window.elementArray(withCode: code("CrTb")).add(ForgeChromeTab(elementCode: code("CrTb"), properties: nil, data: nil))
            let created = tabs(window).filter { !previous.contains(propertyText($0, "ID  ")) }
            guard created.count == 1, let tab = created.first else {
                throw error("BROWSER_AUTOMATION_CREATE_TAB_PROVENANCE_INVALID", "Chrome did not return one newly created tab")
            }
            tab.property(withCode: code("URL ")).setTo(url)
            let afterUrl = propertyText(tab, "URL ")
            guard afterUrl == url else {
                throw error("BROWSER_AUTOMATION_CREATE_TAB_PROVENANCE_INVALID", "Chrome did not accept the exact requested URL")
            }
            if propertyText(try activeTab(window), "ID  ") == propertyText(tab, "ID  "),
               let index = tabs(window).firstIndex(where: { propertyText($0, "ID  ") == previousActiveID }) {
                window.property(withCode: code("acTI")).setTo(NSNumber(value: index + 1))
            }
            return [propertyText(window, "ID  "), propertyText(tab, "ID  "), url, afterUrl].joined(separator: record)
        case "close_tab":
            let (_, tab) = try selected()
            ForgeChromeCloseTab(tab)
            return ""
        case "navigate":
            guard let url else { throw error("BROWSER_AUTOMATION_URL_INVALID", "Missing Chrome URL") }
            let (_, tab) = try selected()
            tab.property(withCode: code("URL ")).setTo(url)
            return url
        case "reload":
            let (_, tab) = try selected()
            ForgeChromeReloadTab(tab)
            return ""
        case "execute_javascript":
            guard let javascript else { throw error("BROWSER_AUTOMATION_JAVASCRIPT_INVALID", "Missing Chrome JavaScript") }
            let (_, tab) = try selected()
            return text(ForgeChromeExecuteJavascript(tab, javascript))
        case "activate":
            let (window, tab) = try selected()
            guard let index = tabs(window).firstIndex(where: { propertyText($0, "ID  ") == propertyText(tab, "ID  ") }) else {
                throw error("BROWSER_AUTOMATION_TAB_NOT_FOUND", "Chrome tab disappeared before activation")
            }
            window.property(withCode: code("acTI")).setTo(NSNumber(value: index + 1))
            window.property(withCode: code("pidx")).setTo(NSNumber(value: 1))
            app.activate()
            return ""
        default:
            throw error("BROWSER_AUTOMATION_ACTION_UNSUPPORTED", "Unsupported process-bound Chrome action")
        }
          }()
        } catch {
            if let failure = failures.lastError {
                throw eventFailure(failure, action: action)
            }
            throw error
        }
        if let failure = failures.lastError {
            throw eventFailure(failure, action: action)
        }
        return result
    }
}
