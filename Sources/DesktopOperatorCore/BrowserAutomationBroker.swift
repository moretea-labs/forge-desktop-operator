import AppKit
import Foundation

public struct BrowserAutomationCommandResult: Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String = "", stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public final class BrowserAutomationBroker {
    public typealias CommandRunner = (_ executable: String, _ arguments: [String], _ timeoutMs: Int) throws -> BrowserAutomationCommandResult

    private struct BrowserDefinition {
        let appName: String
        let bundleIdentifier: String
    }

    private struct TabRef {
        let windowId: String
        let tabId: String
    }

    private static let protocolVersion = 1
    private static let defaultTimeoutMs = 5_000
    private static let maxTimeoutMs = 30_000
    private static let maxURLBytes = 65_536
    private static let maxJavaScriptBytes = 768 * 1_024
    private static let maxCaptureBytes = 3 * 1_048_576
    private static let browsers: [String: BrowserDefinition] = [
        "chrome": BrowserDefinition(appName: "Google Chrome", bundleIdentifier: "com.google.Chrome"),
        "vivaldi": BrowserDefinition(appName: "Vivaldi", bundleIdentifier: "com.vivaldi.Vivaldi"),
    ]

    private let runner: CommandRunner
    private let frontmostBundleIdentifier: () -> String?

    public init() {
        self.runner = Self.runCommand
        self.frontmostBundleIdentifier = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    }

    public init(
        runner: @escaping CommandRunner,
        frontmostBundleIdentifier: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    ) {
        self.runner = runner
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
    }

    public func execute(params: JSONValue) throws -> JSONValue {
        guard let object = params.objectValue else { throw invalid("BROWSER_AUTOMATION_PARAMS_INVALID") }
        guard object["protocolVersion"]?.intValue == Self.protocolVersion else {
            throw invalid("BROWSER_AUTOMATION_PROTOCOL_VERSION_MISMATCH")
        }
        guard let action = object["action"]?.stringValue else { throw invalid("BROWSER_AUTOMATION_ACTION_UNSUPPORTED") }
        let timeoutMs = boundedTimeout(object["timeoutMs"]?.intValue)

        if action == "capture_region" {
            return .object(["base64": .string(try captureRegion(object["region"], timeoutMs: timeoutMs))])
        }

        guard let product = object["product"]?.stringValue, let browser = Self.browsers[product] else {
            throw invalid("BROWSER_AUTOMATION_PRODUCT_INVALID")
        }
        let target = try optionalRef(object["ref"])

        switch action {
        case "metadata":
            return valueResult(authoritativeMetadata(
                try runAppleScript(metadataScript(browser.appName, target), args: [], timeoutMs: timeoutMs),
                browser: browser
            ))
        case "list_tabs":
            guard target == nil else { throw invalid("BROWSER_AUTOMATION_TAB_REF_UNSUPPORTED") }
            return valueResult(try runAppleScript(listTabsScript(browser.appName), args: [], timeoutMs: timeoutMs))
        case "create_tab":
            let url = try boundedString(object["url"], field: "URL", maxBytes: Self.maxURLBytes)
            return try valueResult(runAppleScript(createTabScript(browser.appName), args: [url], timeoutMs: timeoutMs))
        case "close_tab":
            guard let target else { throw invalid("BROWSER_AUTOMATION_TAB_REF_REQUIRED") }
            return try valueResult(runAppleScript(closeTabScript(browser.appName, target), args: [], timeoutMs: timeoutMs))
        case "navigate":
            let url = try boundedString(object["url"], field: "URL", maxBytes: Self.maxURLBytes)
            return try valueResult(runAppleScript(navigateScript(browser.appName, target), args: [url], timeoutMs: timeoutMs))
        case "reload":
            return try valueResult(runAppleScript(reloadScript(browser.appName, target), args: [], timeoutMs: timeoutMs))
        case "execute_javascript":
            let source = try boundedString(object["source"], field: "JAVASCRIPT", maxBytes: Self.maxJavaScriptBytes)
            return try valueResult(runAppleScript(executeJavaScriptScript(browser.appName, target), args: [source], timeoutMs: timeoutMs))
        case "activate":
            return try valueResult(runAppleScript(activateScript(browser.appName, target), args: [], timeoutMs: timeoutMs))
        default:
            throw invalid("BROWSER_AUTOMATION_ACTION_UNSUPPORTED")
        }
    }

    private func boundedTimeout(_ value: Int?) -> Int {
        min(max(value ?? Self.defaultTimeoutMs, 100), Self.maxTimeoutMs)
    }


    private func optionalRef(_ value: JSONValue?) throws -> TabRef? {
        guard let value else { return nil }
        guard let object = value.objectValue,
              let windowId = object["windowId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              let tabId = object["tabId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !windowId.isEmpty, !tabId.isEmpty,
              windowId.count <= 128, tabId.count <= 128 else {
            throw invalid("BROWSER_AUTOMATION_TAB_REF_INVALID")
        }
        return TabRef(windowId: windowId, tabId: tabId)
    }

    private func boundedString(_ value: JSONValue?, field: String, maxBytes: Int) throws -> String {
        guard let value = value?.stringValue, value.utf8.count <= maxBytes else {
            throw invalid("BROWSER_AUTOMATION_\(field)_INVALID")
        }
        return value
    }

    private func valueResult(_ value: String) -> JSONValue {
        .object(["value": .string(value)])
    }

    private func authoritativeMetadata(_ value: String, browser: BrowserDefinition) -> String {
        let separator = String(UnicodeScalar(30)!)
        var parts = value.components(separatedBy: separator)
        guard !parts.isEmpty else { return value }
        parts[0] = frontmostBundleIdentifier() == browser.bundleIdentifier ? "true" : "false"
        return parts.joined(separator: separator)
    }

    private func runAppleScript(_ script: String, args: [String], timeoutMs: Int) throws -> String {
        let result = try runner("/usr/bin/osascript", ["-e", script, "--"] + args, timeoutMs)
        guard result.status == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw failed(message.isEmpty ? "osascript exited with status \(result.status)" : String(message.suffix(2_000)))
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func captureRegion(_ value: JSONValue?, timeoutMs: Int) throws -> String {
        guard let object = value?.objectValue,
              let x = object["x"]?.intValue,
              let y = object["y"]?.intValue,
              let width = object["width"]?.intValue,
              let height = object["height"]?.intValue,
              width >= 1, height >= 1, width <= 20_000, height <= 20_000 else {
            throw invalid("BROWSER_AUTOMATION_REGION_INVALID")
        }
        guard ScreenshotDriver.screenRecordingGranted else {
            throw PluginError(
                code: "SCREEN_RECORDING_NOT_GRANTED",
                message: "Grant Screen & System Audio Recording access to Forge Desktop Operator (com.moretea.forge.desktop-operator) in System Settings > Privacy & Security",
                retryable: true,
                domain: "tcc",
                details: try? JSONValue.encode(DesktopPermissions.screenRecording(granted: false))
            )
        }
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-browser-capture-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: path) }
        let result = try runner(
            "/usr/sbin/screencapture",
            ["-x", "-R", "\(x),\(y),\(width),\(height)", path.path],
            timeoutMs
        )
        guard result.status == 0 else {
            throw failed(result.stderr.isEmpty ? "screencapture exited with status \(result.status)" : result.stderr)
        }
        let bytes = try Data(contentsOf: path)
        guard bytes.count <= Self.maxCaptureBytes else { throw invalid("BROWSER_AUTOMATION_CAPTURE_TOO_LARGE") }
        return bytes.base64EncodedString()
    }

    private func metadataScript(_ appName: String, _ target: TabRef?) -> String {
        if let target {
            return tell(appName, """
            \(targetPreamble(target))
            set windowBounds to bounds of targetWindow
            set separator to ASCII character 30
            set targetIsActive to ((id of active tab of targetWindow) is (id of targetTab))
            return (frontmost as text) & separator & (URL of targetTab as text) & separator & "" & separator & ((item 1 of windowBounds) as text) & separator & ((item 2 of windowBounds) as text) & separator & ((item 3 of windowBounds) as text) & separator & ((item 4 of windowBounds) as text) & separator & ((id of targetWindow) as text) & separator & ((id of targetTab) as text) & separator & (targetIsActive as text) & separator & (loading of targetTab as text)
            """)
        }
        return tell(appName, """
        if (count of windows) is 0 then error "FORGE_NO_BROWSER_WINDOW"
        set targetWindow to front window
        set targetTab to active tab of targetWindow
        set windowBounds to bounds of targetWindow
        set separator to ASCII character 30
        return (frontmost as text) & separator & (URL of targetTab as text) & separator & (title of targetTab as text) & separator & ((item 1 of windowBounds) as text) & separator & ((item 2 of windowBounds) as text) & separator & ((item 3 of windowBounds) as text) & separator & ((item 4 of windowBounds) as text)
        """)
    }

    private func listTabsScript(_ appName: String) -> String {
        """
        on replaceText(sourceText, needle, replacement)
          set previousDelimiters to AppleScript's text item delimiters
          set AppleScript's text item delimiters to needle
          set sourceItems to every text item of sourceText
          set AppleScript's text item delimiters to replacement
          set resultText to sourceItems as text
          set AppleScript's text item delimiters to previousDelimiters
          return resultText
        end replaceText

        on cleanField(sourceText, recordSeparator, fieldSeparator)
          set cleaned to my replaceText(sourceText as text, recordSeparator, " ")
          return my replaceText(cleaned, fieldSeparator, " ")
        end cleanField

        \(tell(appName, """
        set recordSeparator to ASCII character 30
        set fieldSeparator to ASCII character 31
        set maxTabs to 256
        set returnedCount to 0
        set truncatedInventory to false
        set outputText to "false"
        repeat with candidateWindow in windows
          set activeTabId to ""
          try
            set activeTabId to ((id of active tab of candidateWindow) as text)
          end try
          repeat with candidateTab in tabs of candidateWindow
            if returnedCount is greater than or equal to maxTabs then
              set truncatedInventory to true
              exit repeat
            end if
            set candidateWindowId to ((id of candidateWindow) as text)
            set candidateTabId to ((id of candidateTab) as text)
            set candidateURL to my cleanField((URL of candidateTab as text), recordSeparator, fieldSeparator)
            set candidateTitle to my cleanField((title of candidateTab as text), recordSeparator, fieldSeparator)
            set candidateActive to (candidateTabId is activeTabId)
            set outputText to outputText & recordSeparator & candidateWindowId & fieldSeparator & candidateTabId & fieldSeparator & (candidateActive as text) & fieldSeparator & candidateURL & fieldSeparator & candidateTitle
            set returnedCount to returnedCount + 1
          end repeat
          if truncatedInventory then exit repeat
        end repeat
        if truncatedInventory then
          set outputText to "true" & text 6 thru -1 of outputText
        end if
        return outputText
        """))
        """
    }

    private func createTabScript(_ appName: String) -> String {
        """
        on run argv
        set targetUrl to item 1 of argv
        \(tell(appName, """
        if (count of windows) is 0 then error "FORGE_NO_BROWSER_WINDOW"
        set targetWindow to front window
        set originalActiveIndex to active tab index of targetWindow
        set targetTab to make new tab at end of tabs of targetWindow with properties {URL:targetUrl}
        set targetTabId to id of targetTab
        set active tab index of targetWindow to originalActiveIndex
        set separator to ASCII character 30
        return ((id of targetWindow) as text) & separator & (targetTabId as text)
        """))
        end run
        """
    }

    private func closeTabScript(_ appName: String, _ target: TabRef) -> String {
        tell(appName, """
        try
        \(targetPreamble(target))
        close targetTab
        end try
        """)
    }

    private func navigateScript(_ appName: String, _ target: TabRef?) -> String {
        let body = target.map { "\(targetPreamble($0))\nset URL of targetTab to targetUrl\nreturn targetUrl" }
            ?? "if (count of windows) is 0 then error \"FORGE_NO_BROWSER_WINDOW\"\nset URL of active tab of front window to targetUrl\nreturn targetUrl"
        return "on run argv\nset targetUrl to item 1 of argv\n\(tell(appName, body))\nend run"
    }

    private func reloadScript(_ appName: String, _ target: TabRef?) -> String {
        tell(appName, target.map { "\(targetPreamble($0))\nreload targetTab" }
            ?? "if (count of windows) is 0 then error \"FORGE_NO_BROWSER_WINDOW\"\nreload active tab of front window")
    }

    private func executeJavaScriptScript(_ appName: String, _ target: TabRef?) -> String {
        let body = target.map { "\(targetPreamble($0))\nreturn execute targetTab javascript javascriptSource" }
            ?? "if (count of windows) is 0 then error \"FORGE_NO_BROWSER_WINDOW\"\nreturn execute active tab of front window javascript javascriptSource"
        return "on run argv\nset javascriptSource to item 1 of argv\n\(tell(appName, body))\nend run"
    }

    private func activateScript(_ appName: String, _ target: TabRef?) -> String {
        guard let target else { return tell(appName, "activate") }
        return tell(appName, """
        \(targetPreamble(target))
        set targetTabIndex to 1
        repeat with candidateTab in tabs of targetWindow
          if ((id of candidateTab) as text) is ((id of targetTab) as text) then exit repeat
          set targetTabIndex to targetTabIndex + 1
        end repeat
        set active tab index of targetWindow to targetTabIndex
        set index of targetWindow to 1
        activate
        """)
    }

    private func targetPreamble(_ target: TabRef) -> String {
        """
        set targetTabId to \(quoted(target.tabId))
        set targetWindow to missing value
        set targetTab to missing value
        try
          set hintedWindow to first window whose id is \(quoted(target.windowId))
          set hintedTab to first tab of hintedWindow whose id is targetTabId
          set targetWindow to hintedWindow
          set targetTab to hintedTab
        end try
        if targetTab is missing value then
          repeat with candidateWindow in windows
            repeat with candidateTab in tabs of candidateWindow
              if ((id of candidateTab) as text) is targetTabId then
                set targetWindow to candidateWindow
                set targetTab to candidateTab
                exit repeat
              end if
            end repeat
            if targetTab is not missing value then exit repeat
          end repeat
        end if
        if targetTab is missing value then error "FORGE_BROWSER_TAB_NOT_FOUND:" & targetTabId
        """
    }

    private func tell(_ appName: String, _ body: String) -> String {
        "tell application \(quoted(appName))\n\(body)\nend tell"
    }

    private func quoted(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func invalid(_ code: String) -> PluginError {
        PluginError(code: code, message: code, retryable: false, domain: "browser")
    }

    private func failed(_ message: String) -> PluginError {
        PluginError(code: "BROWSER_AUTOMATION_ACTION_FAILED", message: String(message.prefix(2_000)), retryable: true, domain: "browser")
    }

    private static func runCommand(_ executable: String, _ arguments: [String], _ timeoutMs: Int) throws -> BrowserAutomationCommandResult {
        let tempRoot = FileManager.default.temporaryDirectory
        let stdoutURL = tempRoot.appendingPathComponent("forge-desktop-broker-stdout-\(UUID().uuidString)")
        let stderrURL = tempRoot.appendingPathComponent("forge-desktop-broker-stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        try process.run()
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1_000)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw PluginError(code: "BROWSER_AUTOMATION_TIMEOUT", message: "Browser automation command timed out", retryable: true, domain: "browser")
        }
        process.waitUntilExit()
        try stdoutHandle.synchronize()
        try stderrHandle.synchronize()
        let stdout = String(decoding: (try? Data(contentsOf: stdoutURL)) ?? Data(), as: UTF8.self)
        let stderr = String(decoding: (try? Data(contentsOf: stderrURL)) ?? Data(), as: UTF8.self)
        return BrowserAutomationCommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
