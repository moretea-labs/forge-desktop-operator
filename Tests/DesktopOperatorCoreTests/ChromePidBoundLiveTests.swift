import Foundation
import Testing
@testable import DesktopOperatorCore

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
