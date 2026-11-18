import Foundation
import Testing
@testable import DesktopOperatorCore

@Test func chromePidBoundEventFailureIncludesActionAndStage() {
    let timeout = NSError(
        domain: NSOSStatusErrorDomain,
        code: -1712,
        userInfo: [NSLocalizedDescriptionKey: "Apple Event timed out"]
    )
    let result = ChromePidBoundAutomation.eventFailure(
        timeout,
        action: "create_tab",
        stage: "create_tab.snapshot_previous_tabs"
    )
    #expect(result.code == "BROWSER_AUTOMATION_MUTATION_OUTCOME_UNKNOWN")
    #expect(!result.retryable)
    #expect(result.message.contains("action=create_tab"))
    #expect(result.message.contains("stage=create_tab.snapshot_previous_tabs"))
}


/// Bounded, read-only hot-path acceptance against an explicitly supplied live
/// Chrome GUI PID. Unlike the full-inventory acceptance, this only exercises
/// front-window and exact window/tab resolution; it never creates or edits a tab.
@Test(.enabled(if: ProcessInfo.processInfo.environment["FORGE_TEST_CHROME_PID"] != nil))
func chromePidBoundReadOnlyExactWindowHotPath() throws {
    guard let raw = ProcessInfo.processInfo.environment["FORGE_TEST_CHROME_PID"],
          let pid = Int32(raw), pid > 0 else {
        Issue.record("Expected an exact prevalidated GUI Chrome PID")
        return
    }
    let separator = String(UnicodeScalar(30)!)
    func metadata(windowId: String? = nil, tabId: String? = nil) throws -> [String] {
        try ChromePidBoundAutomation.execute(
            pid: pid, action: "metadata", windowId: windowId, tabId: tabId,
            url: nil, javascript: nil, timeoutMs: 5_000, frontmostPID: nil
        ).components(separatedBy: separator)
    }
    let front = try metadata()
    guard front.count >= 10, !front[7].isEmpty, !front[8].isEmpty else {
        Issue.record("Live Chrome front-window metadata lacks stable window/tab identity")
        return
    }
    let windowId = front[7]
    let tabId = front[8]
    let samples = 8
    var frontMs: [Double] = []
    var exactMs: [Double] = []
    for _ in 0..<samples {
        let frontStarted = ProcessInfo.processInfo.systemUptime
        let current = try metadata()
        frontMs.append((ProcessInfo.processInfo.systemUptime - frontStarted) * 1_000)
        #expect(current.count >= 10)
        let exactStarted = ProcessInfo.processInfo.systemUptime
        let bound = try metadata(windowId: windowId, tabId: tabId)
        exactMs.append((ProcessInfo.processInfo.systemUptime - exactStarted) * 1_000)
        #expect(bound.count >= 10)
        guard bound.count >= 10 else { return }
        #expect(bound[7] == windowId)
        #expect(bound[8] == tabId)
    }
    func percentile(_ values: [Double], _ fraction: Double) -> Int {
        let ordered = values.sorted()
        return Int(ordered[max(0, min(ordered.count - 1, Int(ceil(Double(ordered.count) * fraction)) - 1))].rounded())
    }
    print("CHROME_PID_EXACT_WINDOW_HOTPATH_RESULT=PASS samples=\(samples) pid=\(pid) " +
          "front_p50_ms=\(percentile(frontMs, 0.5)) front_p95_ms=\(percentile(frontMs, 0.95)) " +
          "exact_p50_ms=\(percentile(exactMs, 0.5)) exact_p95_ms=\(percentile(exactMs, 0.95))")
}

/// Explicit, read-only real-Chrome acceptance. Never creates, navigates,
/// activates, or closes a user tab. The PID must be supplied for this run.
@Test(.enabled(if: ProcessInfo.processInfo.environment["FORGE_TEST_CHROME_PID"] != nil))
func chromePidBoundReadOnlyRealChromeMetadataAndInventory() throws {
    guard let raw = ProcessInfo.processInfo.environment["FORGE_TEST_CHROME_PID"],
          let pid = Int32(raw), pid > 0 else {
        Issue.record("Expected an exact prevalidated GUI Chrome PID")
        return
    }
    let metadata = try ChromePidBoundAutomation.execute(
        pid: pid, action: "metadata", windowId: nil, tabId: nil,
        url: nil, javascript: nil, timeoutMs: 4_000, frontmostPID: nil
    ).components(separatedBy: String(UnicodeScalar(30)!))
    #expect(metadata.count >= 9, "Native Chrome metadata must include exact window/tab IDs")
    guard metadata.count >= 9 else { return }
    #expect(!metadata[7].isEmpty && !metadata[8].isEmpty)
    let exact = try ChromePidBoundAutomation.execute(
        pid: pid, action: "metadata", windowId: metadata[7], tabId: metadata[8],
        url: nil, javascript: nil, timeoutMs: 4_000, frontmostPID: nil
    ).components(separatedBy: String(UnicodeScalar(30)!))
    #expect(exact.count >= 9)
    if exact.count >= 9 {
        #expect(exact[7] == metadata[7])
        #expect(exact[8] == metadata[8])
    }
    let inventory = try ChromePidBoundAutomation.execute(
        pid: pid, action: "list_tabs", windowId: nil, tabId: nil,
        url: nil, javascript: nil, timeoutMs: 4_000, frontmostPID: nil
    ).components(separatedBy: String(UnicodeScalar(30)!))
    #expect(!inventory.isEmpty)
    #expect(inventory.first == "false", "Native Chrome tab inventory cannot be truncated")
    print("CHROME_PID_READONLY_E2E_RESULT=PASS")
}

/// Same-process, read-only full inventory timing. No tab content leaves
/// the test; only counts and durations are reported, even on repeated runs.
@Test(.enabled(if: ProcessInfo.processInfo.environment["FORGE_TEST_CHROME_PID"] != nil))
func chromePidBoundReadOnlyInventoryTiming() throws {
    guard let raw = ProcessInfo.processInfo.environment["FORGE_TEST_CHROME_PID"],
          let pid = Int32(raw), pid > 0 else { return }
    let record = String(UnicodeScalar(30)!)
    let field = String(UnicodeScalar(31)!)
    var durations: [Int] = []
    var tabCounts: [Int] = []
    var windowCounts: [Int] = []
    for _ in 0..<3 {
        let started = ProcessInfo.processInfo.systemUptime
        let result = try ChromePidBoundAutomation.execute(
            pid: pid, action: "list_tabs", windowId: nil, tabId: nil,
            url: nil, javascript: nil, timeoutMs: 5_000, frontmostPID: nil
        )
        durations.append(Int(((ProcessInfo.processInfo.systemUptime - started) * 1_000).rounded()))
        let records = result.components(separatedBy: record)
        #expect(records.first == "false")
        let rows = records.dropFirst().map { $0.components(separatedBy: field) }
        #expect(!rows.isEmpty)
        guard rows.allSatisfy({ $0.count == 5 && !$0[0].isEmpty && !$0[1].isEmpty &&
            ($0[2] == "true" || $0[2] == "false") }) else {
            Issue.record("Inventory row protocol or identity invalid")
            return
        }
        #expect(Set(rows.map { $0[1] }).count == rows.count)
        let windows = Dictionary(grouping: rows, by: { $0[0] })
        #expect(windows.values.allSatisfy { $0.filter { $0[2] == "true" }.count == 1 })
        tabCounts.append(rows.count)
        windowCounts.append(windows.count)
    }
    print("CHROME_PID_READONLY_INVENTORY_TIMING samples=3 tabs=\(tabCounts) windows=\(windowCounts) ms=\(durations) median_ms=\(durations.sorted()[1])")
}

/// One optional mutation of a disposable tab. Never activates Chrome;
/// cleanup closes only the tab ID returned by this create-tab action.
@Test(.enabled(if: ProcessInfo.processInfo.environment["FORGE_TEST_CHROME_MUTATION"] == "1"))
func chromePidBoundDisposableTabJavaScriptAndMultiFileSelection() throws {
    guard let raw = ProcessInfo.processInfo.environment["FORGE_TEST_CHROME_PID"],
          let pid = Int32(raw), pid > 0 else {
        Issue.record("Missing explicit GUI Chrome PID")
        return
    }
    let separator = String(UnicodeScalar(30)!)
    func call(_ action: String, window: String? = nil, tab: String? = nil, url: String? = nil, js: String? = nil) throws -> String {
        try ChromePidBoundAutomation.execute(
            pid: pid, action: action, windowId: window, tabId: tab,
            url: url, javascript: js, timeoutMs: 8_000, frontmostPID: nil
        )
    }
    let initial = try call("metadata").components(separatedBy: separator)
    #expect(initial.count >= 9)
    guard initial.count >= 9 else { return }
    let initialWindow = initial[7]
    let initialTab = initial[8]
    let uniqueMarker = UUID().uuidString.lowercased()
    let url = "data:text/html,%3C!doctype%20html%3E%3Ctitle%3EForge-%20" + uniqueMarker + "%3C/title%3E%3Cbody%3E"
    let created = try call("create_tab", url: url).components(separatedBy: separator)
    #expect(created.count == 4)
    guard created.count == 4 else { return }
    let window = created[0]
    let tab = created[1]
    defer {
        // No URL guessing, no other tab closed. Attempt only the exact created ID.
        do {
            _ = try call("close_tab", window: window, tab: tab)
        } catch {
            print("CHROME_PID_CREATED_TAB_CLEANUP_ERROR=" + String(describing: error))
        }
    }
    #expect(!window.isEmpty && !tab.isEmpty && tab != initialTab)
    let own = try call("metadata", window: window, tab: tab).components(separatedBy: separator)
    #expect(own.count >= 9)
    if own.count >= 9 {
        #expect(own[7] == window && own[8] == tab)
    }
    let result = try call("execute_javascript", window: window, tab: tab, js:
        "(() => { const input = document.createElement('input'); input.type='file'; input.multiple=true; document.body.append(input); const transfer = new DataTransfer(); transfer.items.add(new File(['first'], 'upload-one.txt')); transfer.items.add(new File(['second'], 'upload-two.txt')); input.files = transfer.files; input.dispatchEvent(new Event('change', { bubbles:true })); return Array.from(input.files).map(f => f.name + ':' + f.size).join(','); })()")
    #expect(result == "upload-one.txt:5,upload-two.txt:6")
    // Closing our disposable tab must not navigate or activate the user's tab.
    let after = try call("metadata").components(separatedBy: separator)
    #expect(after.count >= 9)
    if after.count >= 9 {
        #expect(after[7] == initialWindow)
        #expect(after[8] == initialTab)
    }
    print("CHROME_PID_DISPOSABLE_TAB_E2E_RESULT=PASS")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["FORGE_TEST_CHROME_CLEANUP"] == "1"))
func chromePidBoundCleanupOnlyOwnedDisposableTestTabs() throws {
    guard let raw = ProcessInfo.processInfo.environment["FORGE_TEST_CHROME_PID"],
          let pid = Int32(raw), pid > 0 else { return }
    let record = String(UnicodeScalar(30)!)
    let field = String(UnicodeScalar(31)!)
    let prefix = "data:text/html,%3C!doctype%20html%3E%3Ctitle%3EForge-%20"
    func entries() throws -> [[String]] {
        try ChromePidBoundAutomation.execute(pid: pid, action: "list_tabs",
            windowId: nil, tabId: nil, url: nil, javascript: nil,
            timeoutMs: 8_000, frontmostPID: nil
        ).components(separatedBy: record).dropFirst().map { $0.components(separatedBy: field) }
    }
    let matching = try entries().filter { row in
        row.count == 5 && row[3].hasPrefix(prefix) &&
        row[3].dropFirst(prefix.count).prefix(36).allSatisfy {
            $0.isHexDigit || $0 == "-"
        } && row[2] == "false"
    }
    print("CHROME_PID_OWNED_ORPHANED_TEST_TABS=" + String(matching.count))
    for row in matching {
        _ = try ChromePidBoundAutomation.execute(pid: pid, action: "close_tab",
            windowId: row[0], tabId: row[1], url: nil, javascript: nil,
            timeoutMs: 8_000, frontmostPID: nil)
    }
    let remaining = try entries().filter { $0.count == 5 && $0[3].hasPrefix(prefix) }
    #expect(remaining.isEmpty)
    print("CHROME_PID_OWNED_ORPHANED_TEST_CLEANUP=PASS")
}
