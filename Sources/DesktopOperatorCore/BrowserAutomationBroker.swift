import AppKit
import ApplicationServices
import Foundation

struct BrowserAutomationCommandResult: Equatable {
    let status: Int32
    let stdout: String
    let stderr: String

    init(status: Int32, stdout: String = "", stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

struct BrowserAutomationTrustedInputCommand: Equatable {
    let kind: String
    let x: Double?
    let y: Double?
    let fromX: Double?
    let fromY: Double?
    let toX: Double?
    let toY: Double?
    let deltaX: Double?
    let deltaY: Double?
    let button: String?
    let clickCount: Int?
    let steps: Int?
    let key: String?
    let text: String?
}

final class BrowserAutomationBroker {
    typealias CommandRunner = (_ executable: String, _ arguments: [String], _ timeoutMs: Int) throws -> BrowserAutomationCommandResult
    typealias TrustedInputPerformer = (BrowserAutomationTrustedInputCommand) throws -> Void

    private struct BrowserDefinition {
        let appName: String
        let bundleIdentifier: String
    }

    private struct TabRef {
        let windowId: String
        let tabId: String
    }

    private struct ViewportGeometry {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    static let supportedActions = [
        "metadata",
        "list_tabs",
        "create_tab",
        "close_tab",
        "navigate",
        "reload",
        "execute_javascript",
        "activate",
        "trusted_input",
        "capture_region",
    ]
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
    private let trustedInputPerformer: TrustedInputPerformer

    init() {
        self.runner = Self.runCommand
        self.frontmostBundleIdentifier = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        self.trustedInputPerformer = Self.performTrustedInput
    }

    init(
        runner: @escaping CommandRunner,
        frontmostBundleIdentifier: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    ) {
        self.runner = runner
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.trustedInputPerformer = Self.performTrustedInput
    }

    init(
        runner: @escaping CommandRunner,
        frontmostBundleIdentifier: @escaping () -> String?,
        trustedInputPerformer: @escaping TrustedInputPerformer
    ) {
        self.runner = runner
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.trustedInputPerformer = trustedInputPerformer
    }

    func execute(params: JSONValue) throws -> JSONValue {
        guard let object = params.objectValue else { throw invalid("BROWSER_AUTOMATION_PARAMS_INVALID") }
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
            let output = try runAppleScript(createTabScript(browser.appName), args: [url], timeoutMs: timeoutMs)
            return try createTabResult(output, requestedURL: url)
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
        case "trusted_input":
            guard let target else { throw invalid("BROWSER_AUTOMATION_TAB_REF_REQUIRED") }
            return try trustedInput(object["input"], browser: browser, target: target, timeoutMs: timeoutMs)
        default:
            throw invalid("BROWSER_AUTOMATION_ACTION_UNSUPPORTED")
        }
    }

    private func trustedInput(_ value: JSONValue?, browser: BrowserDefinition, target: TabRef, timeoutMs: Int) throws -> JSONValue {
        let metadata = authoritativeMetadata(
            try runAppleScript(metadataScript(browser.appName, target), args: [], timeoutMs: timeoutMs),
            browser: browser
        ).components(separatedBy: String(UnicodeScalar(30)!))
        guard metadata.count >= 10,
              metadata[0].lowercased() == "true",
              metadata[9].lowercased() == "true" else {
            throw PluginError(
                code: "BROWSER_AUTOMATION_FOREGROUND_REQUIRED",
                message: "Trusted browser input requires the exact saved tab to already be active in the frontmost browser window.",
                retryable: true,
                domain: "browser"
            )
        }
        guard let input = value?.objectValue, let kind = input["kind"]?.stringValue else {
            throw invalid("BROWSER_AUTOMATION_TRUSTED_INPUT_INVALID")
        }

        let pointerKinds: Set<String> = ["click", "move", "wheel", "drag"]
        let geometry = pointerKinds.contains(kind) ? try viewportGeometry(browser: browser, target: target, timeoutMs: timeoutMs) : nil
        let button = input["button"]?.stringValue ?? "left"
        guard ["left", "middle", "right"].contains(button) else { throw invalid("BROWSER_AUTOMATION_TRUSTED_INPUT_INVALID") }

        func finite(_ key: String, min: Double? = nil, max: Double? = nil) throws -> Double {
            guard case .number(let number) = input[key], number.isFinite,
                  min.map({ number >= $0 }) ?? true,
                  max.map({ number <= $0 }) ?? true else {
                throw invalid("BROWSER_AUTOMATION_TRUSTED_INPUT_INVALID")
            }
            return number
        }
        func point(_ xKey: String, _ yKey: String) throws -> (Double, Double) {
            guard let geometry else { throw invalid("BROWSER_AUTOMATION_TRUSTED_INPUT_INVALID") }
            let x = try finite(xKey, min: 0, max: geometry.width)
            let y = try finite(yKey, min: 0, max: geometry.height)
            return (geometry.x + x, geometry.y + y)
        }

        let command: BrowserAutomationTrustedInputCommand
        switch kind {
        case "click":
            let (x, y) = try point("x", "y")
            let clickCount = input["clickCount"]?.intValue ?? 1
            guard (1...3).contains(clickCount) else { throw invalid("BROWSER_AUTOMATION_TRUSTED_INPUT_INVALID") }
            command = BrowserAutomationTrustedInputCommand(kind: kind, x: x, y: y, fromX: nil, fromY: nil, toX: nil, toY: nil, deltaX: nil, deltaY: nil, button: button, clickCount: clickCount, steps: nil, key: nil, text: nil)
        case "move":
            let (x, y) = try point("x", "y")
            let steps = input["steps"]?.intValue ?? 1
            guard (1...100).contains(steps) else { throw invalid("BROWSER_AUTOMATION_TRUSTED_INPUT_INVALID") }
            command = BrowserAutomationTrustedInputCommand(kind: kind, x: x, y: y, fromX: nil, fromY: nil, toX: nil, toY: nil, deltaX: nil, deltaY: nil, button: nil, clickCount: nil, steps: steps, key: nil, text: nil)
        case "wheel":
            guard let geometry else { throw invalid("BROWSER_AUTOMATION_TRUSTED_INPUT_INVALID") }
            let deltaX = try finite("deltaX", min: -100_000, max: 100_000)
            let deltaY = try finite("deltaY", min: -100_000, max: 100_000)
            command = BrowserAutomationTrustedInputCommand(kind: kind, x: geometry.x + geometry.width / 2, y: geometry.y + geometry.height / 2, fromX: nil, fromY: nil, toX: nil, toY: nil, deltaX: deltaX, deltaY: deltaY, button: nil, clickCount: nil, steps: nil, key: nil, text: nil)
        case "drag":
            let (fromX, fromY) = try point("fromX", "fromY")
            let (toX, toY) = try point("toX", "toY")
            let steps = input["steps"]?.intValue ?? 10
            guard (1...100).contains(steps) else { throw invalid("BROWSER_AUTOMATION_TRUSTED_INPUT_INVALID") }
            command = BrowserAutomationTrustedInputCommand(kind: kind, x: nil, y: nil, fromX: fromX, fromY: fromY, toX: toX, toY: toY, deltaX: nil, deltaY: nil, button: button, clickCount: nil, steps: steps, key: nil, text: nil)
        case "key":
            let key = try boundedString(input["key"], field: "TRUSTED_INPUT_KEY", maxBytes: 100)
            guard !key.isEmpty else { throw invalid("BROWSER_AUTOMATION_TRUSTED_INPUT_INVALID") }
            command = BrowserAutomationTrustedInputCommand(kind: kind, x: nil, y: nil, fromX: nil, fromY: nil, toX: nil, toY: nil, deltaX: nil, deltaY: nil, button: nil, clickCount: nil, steps: nil, key: key, text: nil)
        case "text":
            let text = try boundedString(input["text"], field: "TRUSTED_INPUT_TEXT", maxBytes: 40_000)
            guard text.count <= 10_000 else { throw invalid("BROWSER_AUTOMATION_TRUSTED_INPUT_INVALID") }
            command = BrowserAutomationTrustedInputCommand(kind: kind, x: nil, y: nil, fromX: nil, fromY: nil, toX: nil, toY: nil, deltaX: nil, deltaY: nil, button: nil, clickCount: nil, steps: nil, key: nil, text: text)
        default:
            throw invalid("BROWSER_AUTOMATION_TRUSTED_INPUT_INVALID")
        }
        try trustedInputPerformer(command)
        return .object(["performed": .bool(true)])
    }

    private func viewportGeometry(browser: BrowserDefinition, target: TabRef, timeoutMs: Int) throws -> ViewportGeometry {
        let source = "JSON.stringify({screenX:window.screenX,screenY:window.screenY,outerWidth:window.outerWidth,outerHeight:window.outerHeight,innerWidth:window.innerWidth,innerHeight:window.innerHeight})"
        let raw = try runAppleScript(executeJavaScriptScript(browser.appName, target), args: [source], timeoutMs: timeoutMs)
        guard let data = raw.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: NSNumber],
              let screenX = object["screenX"]?.doubleValue,
              let screenY = object["screenY"]?.doubleValue,
              let outerWidth = object["outerWidth"]?.doubleValue,
              let outerHeight = object["outerHeight"]?.doubleValue,
              let innerWidth = object["innerWidth"]?.doubleValue,
              let innerHeight = object["innerHeight"]?.doubleValue,
              innerWidth >= 1, innerHeight >= 1 else {
            throw PluginError(code: "BROWSER_AUTOMATION_VIEWPORT_UNAVAILABLE", message: "Could not resolve browser viewport geometry for trusted input.", retryable: true, domain: "browser")
        }
        let sideInset = max(0, (outerWidth - innerWidth) / 2)
        let topInset = max(0, outerHeight - innerHeight)
        return ViewportGeometry(x: screenX + sideInset, y: screenY + topInset, width: innerWidth, height: innerHeight)
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

    private func createTabResult(_ value: String, requestedURL: String) throws -> JSONValue {
        let separator = String(UnicodeScalar(30)!)
        let parts = value.components(separatedBy: separator)
        guard parts.count == 4, !parts[0].isEmpty, !parts[1].isEmpty, parts[2] == requestedURL else {
            throw PluginError(code: "BROWSER_AUTOMATION_CREATE_TAB_PROVENANCE_INVALID", message: "create_tab did not return stable identity and exact requested-URL assignment proof", retryable: true, domain: "browser")
        }
        let legacyValue = [parts[0], parts[1]].joined(separator: separator)
        return .object([
            "value": .string(legacyValue),
            "ref": .object(["windowId": .string(parts[0]), "tabId": .string(parts[1])]),
            "navigation": .object([
                "provenanceVersion": .number(1),
                "requestedUrl": .string(requestedURL),
                "assignmentAccepted": .bool(true),
                "acceptedBy": .string("chrome_applescript_url_set"),
                "observedUrlAfterAssignment": .string(parts[3]),
            ]),
        ])
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
        set originalActiveTabId to ((id of active tab of targetWindow) as text)
        set targetTab to make new tab at end of tabs of targetWindow
        set targetTabId to id of targetTab
        set URL of targetTab to targetUrl
        set observedUrlAfterAssignment to (URL of targetTab as text)
        set activeTabIdAfterCreate to ((id of active tab of targetWindow) as text)
        if activeTabIdAfterCreate is (targetTabId as text) then
          set candidateIndex to 1
          repeat with candidateTab in tabs of targetWindow
            if ((id of candidateTab) as text) is originalActiveTabId then
              set active tab index of targetWindow to candidateIndex
              exit repeat
            end if
            set candidateIndex to candidateIndex + 1
          end repeat
        end if
        set separator to ASCII character 30
        return ((id of targetWindow) as text) & separator & (targetTabId as text) & separator & targetUrl & separator & observedUrlAfterAssignment
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

    private static func performTrustedInput(_ command: BrowserAutomationTrustedInputCommand) throws {
        guard AXIsProcessTrusted() else {
            throw PluginError(
                code: "ACCESSIBILITY_NOT_GRANTED",
                message: "Grant Accessibility access to Forge Desktop Operator before using trusted browser input.",
                retryable: true,
                domain: "tcc"
            )
        }
        switch command.kind {
        case "click":
            try InputDriver.click(x: command.x!, y: command.y!, button: command.button ?? "left", clickCount: command.clickCount ?? 1)
        case "move":
            try InputDriver.move(x: command.x!, y: command.y!, steps: command.steps ?? 1)
        case "wheel":
            try InputDriver.wheel(x: command.x!, y: command.y!, deltaX: command.deltaX!, deltaY: command.deltaY!)
        case "drag":
            try InputDriver.drag(fromX: command.fromX!, fromY: command.fromY!, toX: command.toX!, toY: command.toY!, button: command.button ?? "left", steps: command.steps ?? 10)
        case "key":
            try InputDriver.press(keys: (command.key ?? "").split(separator: "+").map(String.init))
        case "text":
            try InputDriver.typeUnicode(command.text ?? "", replaceExisting: false)
        default:
            throw PluginError.invalidArguments("Unsupported trusted input kind: \(command.kind)")
        }
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
