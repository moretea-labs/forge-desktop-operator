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
        var currentStage = "window_inventory"
        var failedStage: String?

        func begin(_ stage: String) {
            currentStage = stage
        }

        func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: Error) -> Any? {
            lastError = error
            failedStage = currentStage
            return nil
        }
    }

    private static let record = String(UnicodeScalar(30)!)
    private static let field = String(UnicodeScalar(31)!)
    private static let maxWindows = 128
    private static let maxTabs = 500

    // Apple Event callbacks can arrive after an action was attempted. Even a
    // failed call may have changed a tab; never mark its outcome safe to replay.
    static func eventFailure(_ error: Error, action: String, stage: String = "unknown") -> PluginError {
        let code = (action == "metadata" || action == "list_tabs" || action == "read_text")
            ? "BROWSER_AUTOMATION_NATIVE_EVENT_FAILED"
            : "BROWSER_AUTOMATION_MUTATION_OUTCOME_UNKNOWN"
        return PluginError(
            code: code,
            message: "Process-bound Chrome Apple Event failed [action=\(action), stage=\(stage)]: " +
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
    // The ScriptingBridge collection can remain live after get(). Copy by
    // bounded indexed access across the Objective-C exception boundary.
    // A failed snapshot must not authorize any subsequent tab mutation.
    private static func snapshot(_ elements: SBElementArray?, limit: Int) throws -> [SBObject] {
        var nativeError: NSError?
        guard let objects = ForgeChromeSnapshotElements(elements, UInt(limit), &nativeError) else {
            throw error("BROWSER_AUTOMATION_NATIVE_COLLECTION_CHANGED",
                        nativeError?.localizedDescription ?? "Chrome collection could not be snapshotted")
        }
        return objects
    }
    private static func windows(_ app: SBApplication) throws -> [SBObject] {
        try snapshot(app.elementArray(withCode: code("cwin")), limit: maxWindows)
    }
    private static func frontWindow(_ app: ForgeChromeApplication, failures: FailureRecorder) throws -> SBObject {
        failures.begin("front_window")
        var nativeError: NSError?
        guard let window = ForgeChromeElementAtIndex(
            app.elementArray(withCode: code("cwin")), 0, &nativeError
        ) else {
            if let nativeError {
                throw error("BROWSER_AUTOMATION_NATIVE_COLLECTION_CHANGED", nativeError.localizedDescription)
            }
            throw error("BROWSER_AUTOMATION_NO_WINDOW", "Chrome has no scriptable GUI window")
        }
        return window
    }
    private static func exactWindow(
        _ app: ForgeChromeApplication, id: String, action: String, failures: FailureRecorder
    ) throws -> SBObject? {
        guard let numericWindowId = Int64(id) else { return nil }
        let elements = app.elementArray(withCode: code("cwin"))
        failures.begin("resolve_exact_window")
        let direct = elements.object(withID: NSNumber(value: numericWindowId)) as? SBObject
        if let direct, propertyText(direct, "ID  ") == id { return direct }
        if let failure = failures.lastError {
            // A moved/closed window may yield -1728. Only that exact lookup miss
            // is safe to discard before the exceptional global moved-tab scan.
            guard isExpectedMissingTabLookup(failure) else {
                throw eventFailure(failure, action: action, stage: failures.failedStage ?? "resolve_exact_window")
            }
            failures.lastError = nil
            failures.failedStage = nil
        }
        return nil
    }
    private static func tabs(_ window: SBObject) throws -> [SBObject] {
        try snapshot(window.elementArray(withCode: code("CrTb")), limit: maxTabs)
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
    static func isExpectedMissingTabLookup(_ failure: Error) -> Bool {
        let nativeError = failure as NSError
        return nativeError.domain == NSOSStatusErrorDomain && nativeError.code == -1728
    }

    private static func exactTab(
        _ app: ForgeChromeApplication, action: String, windowId: String, tabId: String,
        failures: FailureRecorder
    ) throws -> (SBObject, SBObject) {
        // The controller already has an exact window/tab pair. Resolve both IDs
        // directly; the ordinary action path must not materialize every Chrome
        // window (or tab) before using the exact binding. A moved tab is the
        // exceptional path: only then scan the global inventory by unique tab ID.
        if !windowId.isEmpty,
           let window = try exactWindow(app, id: windowId, action: action, failures: failures) {
            if let numericTabId = Int64(tabId) {
                let direct = window.elementArray(withCode: code("CrTb"))
                    .object(withID: NSNumber(value: numericTabId)) as? SBObject
                if let direct, propertyText(direct, "ID  ") == tabId {
                    return (window, direct)
                }
                if let failure = failures.lastError {
                    guard isExpectedMissingTabLookup(failure) else {
                        throw eventFailure(failure, action: action, stage: failures.failedStage ?? "exact_tab_lookup")
                    }
                    failures.lastError = nil
                    failures.failedStage = nil
                }
            }
            let local = try tabs(window).filter { propertyText($0, "ID  ") == tabId }
            guard local.count <= 1 else {
                throw error("BROWSER_AUTOMATION_TAB_NOT_FOUND", "Chrome tab identity is ambiguous")
            }
            if let tab = local.first { return (window, tab) }
        }
        let matches = try windows(app).flatMap { window -> [(SBObject, SBObject)] in
            try tabs(window).filter { propertyText($0, "ID  ") == tabId }.map { (window, $0) }
        }
        guard matches.count == 1 else {
            throw error("BROWSER_AUTOMATION_TAB_NOT_FOUND", "Chrome tab identity is absent or ambiguous")
        }
        return matches[0]
    }
    // An exact, validated target ID is invariant throughout the index scan.
    // Keep one read per candidate and stop at the first match. In particular,
    // never issue a mutation after an identity read fails.
    static func activationIndex<T>(
        target: T, candidates: [T], readID: (T) throws -> String
    ) rethrows -> Int? {
        let targetID = try readID(target)
        guard !targetID.isEmpty else { return nil }
        return try candidates.firstIndex { candidate in
            try readID(candidate) == targetID
        }
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
        func selected() throws -> (SBObject, SBObject) {
            if let tabId, !tabId.isEmpty {
                failures.begin("resolve_exact_tab")
                return try exactTab(app, action: action, windowId: windowId ?? "", tabId: tabId, failures: failures)
            }
            guard action == "metadata" || action == "list_tabs" else {
                throw error("BROWSER_AUTOMATION_TAB_REF_REQUIRED", "A Chrome mutation requires an exact bound tab")
            }
            let window = try frontWindow(app, failures: failures)
            failures.begin("read_active_tab")
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
            failures.begin("window_inventory")
            let allWindows = try windows(app)
            var entries: [String] = []
            var truncated = false
            for window in allWindows {
                // Stable window identity is shared by every row belonging to
                // this window. Do not send the same Apple Event for each tab.
                let windowID = propertyText(window, "ID  ")
                let activeID = propertyText(try activeTab(window), "ID  ")
                for tab in try tabs(window) {
                    if entries.count == maxTabs { truncated = true; break }
                    // One live tab ID supplies both row identity and the active
                    // comparison. Keep the complete inventory and all fields.
                    let tabID = propertyText(tab, "ID  ")
                    entries.append([
                        windowID,
                        tabID,
                        String(tabID == activeID),
                        boundedField(propertyText(tab, "URL ")),
                        boundedField(propertyText(tab, "pnam")),
                    ].joined(separator: field))
                }
                if truncated { break }
            }
            return ([String(truncated)] + entries).joined(separator: record)
        case "create_tab":
            guard let url, !url.isEmpty else {
                throw error("BROWSER_AUTOMATION_CREATE_TAB_INVALID", "Chrome tab creation needs a URL and an existing window")
            }
            let window = try frontWindow(app, failures: failures)
            failures.begin("create_tab.read_previous_active_tab")
            let previousActiveID = propertyText(try activeTab(window), "ID  ")
            failures.begin("create_tab.snapshot_previous_tabs")
            let previous = Set(try tabs(window).map { propertyText($0, "ID  ") })
            failures.begin("create_tab.add")
            window.elementArray(withCode: code("CrTb")).add(ForgeChromeTab(elementCode: code("CrTb"), properties: nil, data: nil))
            failures.begin("create_tab.snapshot_created_tabs")
            let created = try tabs(window).filter { !previous.contains(propertyText($0, "ID  ")) }
            guard created.count == 1, let tab = created.first else {
                throw error("BROWSER_AUTOMATION_CREATE_TAB_PROVENANCE_INVALID", "Chrome did not return one newly created tab")
            }
            failures.begin("create_tab.set_url")
            tab.property(withCode: code("URL ")).setTo(url)
            failures.begin("create_tab.verify_url")
            let afterUrl = propertyText(tab, "URL ")
            guard afterUrl == url else {
                throw error("BROWSER_AUTOMATION_CREATE_TAB_PROVENANCE_INVALID", "Chrome did not accept the exact requested URL")
            }
            failures.begin("create_tab.read_active_tab_after")
            let activeAfterCreateID = propertyText(try activeTab(window), "ID  ")
            if activeAfterCreateID == propertyText(tab, "ID  ") {
                failures.begin("create_tab.snapshot_previous_active_tab_index")
                if let index = try tabs(window).firstIndex(where: { propertyText($0, "ID  ") == previousActiveID }) {
                    failures.begin("create_tab.restore_previous_active_tab")
                    window.property(withCode: code("acTI")).setTo(NSNumber(value: index + 1))
                }
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
        case "execute_javascript", "read_text":
            guard let javascript else { throw error("BROWSER_AUTOMATION_JAVASCRIPT_INVALID", "Missing Chrome JavaScript") }
            let (_, tab) = try selected()
            return text(ForgeChromeExecuteJavascript(tab, javascript))
        case "activate":
            let (window, tab) = try selected()
            failures.begin("activate.resolve_tab_index")
            let candidates = try tabs(window)
            guard let index = try activationIndex(target: tab, candidates: candidates, readID: { element in
                let id = propertyText(element, "ID  ")
                if let failure = failures.lastError {
                    throw eventFailure(failure, action: action, stage: failures.failedStage ?? "activate.resolve_tab_index")
                }
                return id
            }) else {
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
                throw eventFailure(
                    failure, action: action,
                    stage: failures.failedStage ?? failures.currentStage
                )
            }
            throw error
        }
        if let failure = failures.lastError {
            throw eventFailure(
                failure, action: action,
                stage: failures.failedStage ?? failures.currentStage
            )
        }
        return result
    }
}
