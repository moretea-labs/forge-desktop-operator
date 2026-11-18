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
        private let app: ForgeChromeApplication
        private let action: String
        private let deadline: TimeInterval

        init(app: ForgeChromeApplication, action: String, deadline: TimeInterval) {
            self.app = app
            self.action = action
            self.deadline = deadline
        }

        /// One deadline belongs to the whole native action. Derive the
        /// remaining Apple Event reply budget immediately before each event.
        func prepareEvent() throws {
            guard let ticks = ChromePidBoundAutomation.remainingEventTicks(
                deadline: deadline, now: ProcessInfo.processInfo.systemUptime
            ) else {
                throw ChromePidBoundAutomation.eventFailure(
                    NSError(domain: NSOSStatusErrorDomain, code: -1712,
                            userInfo: [NSLocalizedDescriptionKey: "Native action deadline exhausted"]),
                    action: action, stage: currentStage + ".deadline"
                )
            }
            app.timeout = ticks
        }

        /// Never send a mutation after a previous identity/probe event failed.
        func prepareMutation() throws {
            if let failure = lastError {
                throw ChromePidBoundAutomation.eventFailure(
                    failure, action: action, stage: failedStage ?? currentStage
                )
            }
            try prepareEvent()
        }

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

    private static func value(_ object: SBObject, _ key: String, failures: FailureRecorder) throws -> Any? {
        try failures.prepareEvent()
        return object.property(withCode: code(key)).get()
    }
    private static func text(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }
    private static func propertyText(_ object: SBObject, _ key: String, failures: FailureRecorder) throws -> String {
        text(try value(object, key, failures: failures))
    }
    // The ScriptingBridge collection can remain live after get(). Copy by
    // bounded indexed access across the Objective-C exception boundary.
    // A failed snapshot must not authorize any subsequent tab mutation.
    private static func snapshot(_ elements: SBElementArray?, limit: Int, failures: FailureRecorder) throws -> [SBObject] {
        try failures.prepareEvent()
        var nativeError: NSError?
        guard let objects = ForgeChromeSnapshotElements(elements, UInt(limit), &nativeError) else {
            throw error("BROWSER_AUTOMATION_NATIVE_COLLECTION_CHANGED",
                        nativeError?.localizedDescription ?? "Chrome collection could not be snapshotted")
        }
        return objects
    }
    private static func windows(_ app: SBApplication, failures: FailureRecorder) throws -> [SBObject] {
        try snapshot(app.elementArray(withCode: code("cwin")), limit: maxWindows, failures: failures)
    }
    private static func frontWindow(_ app: ForgeChromeApplication, failures: FailureRecorder) throws -> SBObject {
        failures.begin("front_window")
        try failures.prepareEvent()
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
        try failures.prepareEvent()
        let direct = elements.object(withID: NSNumber(value: numericWindowId)) as? SBObject
        if let direct, try propertyText(direct, "ID  ", failures: failures) == id { return direct }
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
    private static func tabs(_ window: SBObject, failures: FailureRecorder) throws -> [SBObject] {
        try snapshot(window.elementArray(withCode: code("CrTb")), limit: maxTabs, failures: failures)
    }

    private static func boundedField(_ field: String) -> String {
        field.replacingOccurrences(of: record, with: "")
             .replacingOccurrences(of: self.field, with: "")
    }
    private static func activeTab(_ window: SBObject, failures: FailureRecorder) throws -> SBObject {
        guard let tab = try value(window, "acTa", failures: failures) as? SBObject else {
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
                try failures.prepareEvent()
                let direct = window.elementArray(withCode: code("CrTb"))
                    .object(withID: NSNumber(value: numericTabId)) as? SBObject
                if let direct, try propertyText(direct, "ID  ", failures: failures) == tabId {
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
            let local = try tabs(window, failures: failures).filter { try propertyText($0, "ID  ", failures: failures) == tabId }
            guard local.count <= 1 else {
                throw error("BROWSER_AUTOMATION_TAB_NOT_FOUND", "Chrome tab identity is ambiguous")
            }
            if let tab = local.first { return (window, tab) }
        }
        let matches = try windows(app, failures: failures).flatMap { window -> [(SBObject, SBObject)] in
            try tabs(window, failures: failures).filter { try propertyText($0, "ID  ", failures: failures) == tabId }.map { (window, $0) }
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
    // SBApplication.timeout is measured in Apple Event Manager ticks
    // (1/60 second), not seconds or milliseconds. Round up to a whole
    // positive tick; never pass kAEDefaultTimeout or kNoTimeOut.
    static func appleEventTimeoutTicks(_ timeoutMs: Int) -> Int {
        let milliseconds = max(1, timeoutMs)
        return (milliseconds / 1_000) * 60 + ((milliseconds % 1_000) * 60 + 999) / 1_000
    }

    static func remainingEventTicks(deadline: TimeInterval, now: TimeInterval) -> Int? {
        let remaining = deadline - now
        guard remaining > 0 else { return nil }
        // No single reply renews the operation budget. Apple Events can only
        // represent whole ticks; round up at most one tick.
        return appleEventTimeoutTicks(Int((remaining * 1_000).rounded(.up)))
    }

    private static func checkedApp(pid: pid_t, timeoutMs: Int) throws -> ForgeChromeApplication {
        guard let running = NSRunningApplication(processIdentifier: pid) else {
            throw error("BROWSER_AUTOMATION_PROCESS_IDENTITY_LOST",
                        "Verified GUI Chrome PID is no longer registered [stage=appkit_lookup]")
        }
        guard running.bundleIdentifier == "com.google.Chrome",
              running.executableURL?.path.hasSuffix("/Google Chrome.app/Contents/MacOS/Google Chrome") == true else {
            throw error("BROWSER_AUTOMATION_PROCESS_IDENTITY_LOST",
                        "Verified GUI Chrome PID no longer has the exact Chrome executable identity [stage=appkit_identity]")
        }
        guard let app = ForgeChromeApplication(processIdentifier: pid) else {
            throw error("BROWSER_AUTOMATION_PROCESS_IDENTITY_LOST",
                        "Cannot bind ScriptingBridge to the verified Chrome PID [stage=scripting_bridge_binding]")
        }
        app.timeout = appleEventTimeoutTicks(timeoutMs)
        guard app.isRunning else {
            throw error("BROWSER_AUTOMATION_PROCESS_IDENTITY_LOST",
                        "ScriptingBridge no longer observes the exact Chrome PID as running [stage=scripting_bridge_running]")
        }
        return app
    }

    static func execute(
        pid: pid_t, action: String, windowId: String?, tabId: String?,
        url: String?, javascript: String?, timeoutMs: Int,
        frontmostPID: pid_t?
    ) throws -> String {
        let deadline = ProcessInfo.processInfo.systemUptime + Double(max(1, timeoutMs)) / 1_000
        let app = try checkedApp(pid: pid, timeoutMs: timeoutMs)
        let failures = FailureRecorder(app: app, action: action, deadline: deadline)
        app.delegate = failures
        defer { app.delegate = nil }
        let result: String
        do {
          result = try { () throws -> String in
        func read(_ object: SBObject, _ key: String) throws -> String {
            try propertyText(object, key, failures: failures)
        }
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
            return (window, try activeTab(window, failures: failures))
        }
        switch action {
        case "metadata":
            let (window, tab) = try selected()
            let bounds = (try value(window, "pbnd", failures: failures) as? NSValue)?.rectValue ?? .zero
            // Trusted input must never be authorized by an active tab in a
            // background Chrome window merely because the app is foreground.
            let frontmost = try frontmostPID == pid && read(window, "pidx") == "1"
            let active = try read(activeTab(window, failures: failures), "ID  ") == read(tab, "ID  ")
            return [
                String(frontmost), boundedField(try read(tab, "URL ")),
                tabId == nil ? boundedField(try read(tab, "pnam")) : "",
                String(Int(bounds.minX)), String(Int(bounds.minY)),
                String(Int(bounds.maxX)), String(Int(bounds.maxY)),
                try read(window, "ID  "), try read(tab, "ID  "),
                String(active), String(text(try value(tab, "ldng", failures: failures)) == "1"),
            ].joined(separator: record)
        case "list_tabs":
            failures.begin("window_inventory")
            let allWindows = try windows(app, failures: failures)
            var entries: [String] = []
            var truncated = false
            for window in allWindows {
                // Stable window identity is shared by every row belonging to
                // this window. Do not send the same Apple Event for each tab.
                let windowID = try read(window, "ID  ")
                let activeID = try read(try activeTab(window, failures: failures), "ID  ")
                for tab in try tabs(window, failures: failures) {
                    if entries.count == maxTabs { truncated = true; break }
                    // One live tab ID supplies both row identity and the active
                    // comparison. Keep the complete inventory and all fields.
                    let tabID = try read(tab, "ID  ")
                    entries.append([
                        windowID,
                        tabID,
                        String(tabID == activeID),
                        boundedField(try read(tab, "URL ")),
                        boundedField(try read(tab, "pnam")),
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
            let previousActiveID = try read(try activeTab(window, failures: failures), "ID  ")
            failures.begin("create_tab.snapshot_previous_tabs")
            let previous = Set(try tabs(window, failures: failures).map { try read($0, "ID  ") })
            failures.begin("create_tab.add")
            try failures.prepareMutation()
            window.elementArray(withCode: code("CrTb")).add(ForgeChromeTab(elementCode: code("CrTb"), properties: nil, data: nil))
            failures.begin("create_tab.snapshot_created_tabs")
            let created = try tabs(window, failures: failures).filter { !previous.contains(try read($0, "ID  ")) }
            guard created.count == 1, let tab = created.first else {
                throw error("BROWSER_AUTOMATION_CREATE_TAB_PROVENANCE_INVALID", "Chrome did not return one newly created tab")
            }
            failures.begin("create_tab.set_url")
            try failures.prepareMutation()
            tab.property(withCode: code("URL ")).setTo(url)
            failures.begin("create_tab.verify_url")
            let afterUrl = try read(tab, "URL ")
            guard afterUrl == url else {
                throw error("BROWSER_AUTOMATION_CREATE_TAB_PROVENANCE_INVALID", "Chrome did not accept the exact requested URL")
            }
            failures.begin("create_tab.read_active_tab_after")
            let activeAfterCreateID = try read(try activeTab(window, failures: failures), "ID  ")
            if try activeAfterCreateID == read(tab, "ID  ") {
                failures.begin("create_tab.snapshot_previous_active_tab_index")
                if let index = try tabs(window, failures: failures).firstIndex(where: { try read($0, "ID  ") == previousActiveID }) {
                    failures.begin("create_tab.restore_previous_active_tab")
                    try failures.prepareMutation()
                    window.property(withCode: code("acTI")).setTo(NSNumber(value: index + 1))
                }
            }
            return [try read(window, "ID  "), try read(tab, "ID  "), url, afterUrl].joined(separator: record)
        case "close_tab":
            let (_, tab) = try selected()
            try failures.prepareMutation()
            ForgeChromeCloseTab(tab)
            return ""
        case "navigate":
            guard let url else { throw error("BROWSER_AUTOMATION_URL_INVALID", "Missing Chrome URL") }
            let (_, tab) = try selected()
            try failures.prepareMutation()
            tab.property(withCode: code("URL ")).setTo(url)
            return url
        case "reload":
            let (_, tab) = try selected()
            try failures.prepareMutation()
            ForgeChromeReloadTab(tab)
            return ""
        case "execute_javascript", "read_text":
            guard let javascript else { throw error("BROWSER_AUTOMATION_JAVASCRIPT_INVALID", "Missing Chrome JavaScript") }
            let (_, tab) = try selected()
            try failures.prepareMutation()
            return text(ForgeChromeExecuteJavascript(tab, javascript))
        case "activate":
            let (window, tab) = try selected()
            failures.begin("activate.resolve_tab_index")
            let candidates = try tabs(window, failures: failures)
            guard let index = try activationIndex(target: tab, candidates: candidates, readID: { element in
                let id = try read(element, "ID  ")
                if let failure = failures.lastError {
                    throw eventFailure(failure, action: action, stage: failures.failedStage ?? "activate.resolve_tab_index")
                }
                return id
            }) else {
                throw error("BROWSER_AUTOMATION_TAB_NOT_FOUND", "Chrome tab disappeared before activation")
            }
            try failures.prepareMutation()
            window.property(withCode: code("acTI")).setTo(NSNumber(value: index + 1))
            try failures.prepareMutation()
            window.property(withCode: code("pidx")).setTo(NSNumber(value: 1))
            try failures.prepareMutation()
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
