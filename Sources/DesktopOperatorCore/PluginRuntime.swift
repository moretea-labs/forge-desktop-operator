import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public final class PluginRuntime {
    public let startedAt = Date()
    public let sessions = DesktopSessionStore()
    public let accessibility = AccessibilityDriver()
    public let browserAutomation: BrowserAutomationBroker
    public private(set) var shutdownRequested = false
    public let socketPath: String
    private let uiLock = NSRecursiveLock()
    private let browserLock = NSRecursiveLock()

    public init(
        socketPath: String = PluginPaths.defaultSocketPath,
        browserAutomation: BrowserAutomationBroker = BrowserAutomationBroker()
    ) {
        self.socketPath = socketPath
        self.browserAutomation = browserAutomation
    }

    public func handle(_ request: RPCRequest) -> RPCResponse {
        do {
            return RPCResponse(id: request.id, result: try dispatch(request))
        } catch let error as PluginError {
            return RPCResponse(id: request.id, error: error)
        } catch {
            return RPCResponse(id: request.id, error: PluginError(code: "INTERNAL_ERROR", message: error.localizedDescription, retryable: false, domain: "runtime"))
        }
    }

    public func health() -> HealthResult {
        var warnings: [String] = []
        if !accessibility.trusted { warnings.append("Accessibility permission is not granted") }
        if !ScreenshotDriver.screenRecordingGranted { warnings.append("Screen Recording permission is not granted") }
        return HealthResult(
            state: warnings.isEmpty ? "ready" : "degraded",
            checkedAt: Date(),
            platform: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            accessibilityTrusted: accessibility.trusted,
            screenRecordingGranted: ScreenshotDriver.screenRecordingGranted,
            activeSessionCount: sessions.count,
            socketPath: socketPath,
            providerBundleIdentifier: DesktopOperatorIdentity.bundleIdentifier,
            providerApplicationPath: DesktopOperatorIdentity.bundlePath,
            permissions: [
                DesktopPermissions.accessibility(granted: accessibility.trusted),
                DesktopPermissions.screenRecording(granted: ScreenshotDriver.screenRecordingGranted),
            ],
            warnings: warnings
        )
    }

    public func execute(action: String, arguments: JSONValue) throws -> JSONValue {
        let object = try requireObject(arguments, name: "arguments")
        switch action {
        case "desktop_status":
            return try JSONValue.encode([
                "health": try JSONValue.encode(health()),
                "sessions": try JSONValue.encode(sessions.records()),
                "applications": .array(ApplicationDriver.runningApplicationSummaries(limit: object["limit"]?.intValue ?? 100))
            ] as [String: JSONValue])
        case "desktop_permissions_request":
            return try withUILock {
                let values = object["services"]?.arrayValue ?? [.string("accessibility"), .string("screen_recording")]
                guard !values.isEmpty, values.count <= 2 else {
                    throw PluginError.invalidArguments("desktop_permissions_request supports 1 or 2 services")
                }
                let services = try values.map { value -> String in
                    guard let service = value.stringValue else { throw PluginError.invalidArguments("services must contain strings") }
                    guard ["accessibility", "screen_recording"].contains(service) else {
                        throw PluginError.invalidArguments("unsupported desktop permission service: \(service)")
                    }
                    return service
                }
                guard Set(services).count == services.count else { throw PluginError.invalidArguments("desktop permission services must be unique") }
                var requested: [String: JSONValue] = [:]
                for service in services {
                    if service == "accessibility" {
                        requested[service] = .bool(AccessibilityDriver.requestTrustPrompt())
                    } else {
                        requested[service] = .bool(ScreenshotDriver.requestScreenRecordingAccess())
                    }
                }
                let current = health()
                return .object([
                    "requested": .object(requested),
                    "permissions": try JSONValue.encode(current.permissions),
                    "health": try JSONValue.encode(current),
                ])
            }
        case "desktop_session_open":
            let bundleId = object["bundle_id"]?.stringValue
            let appName = object["app_name"]?.stringValue
            let launch = object["launch"]?.boolValue ?? true
            let activate = object["activate"]?.boolValue ?? false
            let openSession: () throws -> JSONValue = {
                let application = try ApplicationDriver.ensureRunning(
                    bundleIdentifier: bundleId,
                    appName: appName,
                    launch: launch
                )
                if activate {
                    try ApplicationDriver.activate(application)
                }
                return try JSONValue.encode(self.sessions.create(application: application).record)
            }
            return try launch ? withUILock(openSession) : openSession()
        case "desktop_observe":
            let session = try session(from: object)
            let rootSelector = object["root_selector"] == nil ? nil : try parseSelector(object["root_selector"])
            let focused = rootSelector != nil
            // Focused observations are a payload/latency fast path. Action names and
            // CGWindow enumeration are not required for selector resolution or later
            // press/type calls, so skip those IPCs unless the caller opts back in.
            let includeActions = object["include_actions"]?.boolValue ?? !focused
            let includeWindows = object["include_windows"]?.boolValue ?? !focused
            return try session.withLock {
                let snapshot = try accessibility.snapshot(
                    session: session,
                    maxDepth: object["max_depth"]?.intValue ?? 8,
                    maxNodes: object["max_nodes"]?.intValue ?? 500,
                    includeValues: object["include_values"]?.boolValue ?? true,
                    includeActions: includeActions,
                    rootSelector: rootSelector
                )
                let windows = includeWindows ? ApplicationDriver.windows(pid: session.record.pid) : []
                return .object([
                    "snapshot": try JSONValue.encode(snapshot),
                    "windows": try JSONValue.encode(windows)
                ])
            }
        case "desktop_press":
            let session = try session(from: object)
            let selector = try parseSelector(object["selector"])
            return try withUILock {
                try session.withLock {
                    try accessibility.press(
                        session: session,
                        selector: selector,
                        coordinateFallback: object["coordinate_fallback"]?.boolValue ?? false,
                        forceCoordinate: object["force_coordinate"]?.boolValue ?? false,
                        semanticAction: object["semantic_action"]?.stringValue ?? "press"
                    )
                }
            }
        case "desktop_type_text":
            let session = try session(from: object)
            let selector = try parseSelector(object["selector"])
            guard let text = object["text"]?.stringValue else { throw PluginError.invalidArguments("desktop_type_text requires text") }
            return try withUILock {
                try session.withLock {
                    try accessibility.typeText(session: session, selector: selector, text: text, replaceExisting: object["replace"]?.boolValue ?? true)
                }
            }
        case "desktop_key":
            guard let values = object["keys"]?.arrayValue else { throw PluginError.invalidArguments("desktop_key requires keys") }
            let keys = try values.map { value -> String in
                guard let key = value.stringValue else { throw PluginError.invalidArguments("keys must contain strings") }
                return key
            }
            guard let interactionId = object["interaction_id"]?.stringValue else {
                throw PluginError(code: "DESKTOP_KEY_REQUIRES_INTERACTION_ID", message: "Silent key input requires an explicit desktop session and never targets the user's current foreground app implicitly.", retryable: false, domain: "input")
            }
            let session = try sessions.get(interactionId)
            return try withUILock {
                try session.withLock {
                    guard ApplicationDriver.isActive(pid: session.record.pid) else {
                        throw PluginError(code: "BACKGROUND_SAFE_KEY_INPUT_UNAVAILABLE", message: "Synthetic key events require the target application to already be foreground; Forge Desktop Operator will not activate it automatically.", retryable: true, domain: "input")
                    }
                    try InputDriver.press(keys: keys)
                    return .object(["pressed": .array(keys.map(JSONValue.string))])
                }
            }
        case "desktop_clipboard_read":
            return .object([
                "has_text": .bool(ClipboardDriver.readText() != nil),
                "text": ClipboardDriver.readText().map(JSONValue.string) ?? .null
            ])
        case "desktop_clipboard_write":
            guard let text = object["text"]?.stringValue else { throw PluginError.invalidArguments("desktop_clipboard_write requires text") }
            guard ClipboardDriver.writeText(text) else {
                throw PluginError(code: "CLIPBOARD_WRITE_FAILED", message: "Could not write plain text to the system clipboard", retryable: true, domain: "clipboard")
            }
            return .object(["written": .bool(true), "character_count": .number(Double(text.count))])
        case "desktop_copy":
            guard let interactionId = object["interaction_id"]?.stringValue else { throw PluginError.invalidArguments("desktop_copy requires interaction_id") }
            let session = try sessions.get(interactionId)
            return try withUILock {
                try session.withLock {
                    guard ApplicationDriver.isActive(pid: session.record.pid) else {
                        throw PluginError(code: "BACKGROUND_SAFE_COPY_UNAVAILABLE", message: "Copy requires the target application to already be foreground; silent mode will not activate it.", retryable: true, domain: "input")
                    }
                    try InputDriver.press(keys: ["command", "c"])
                    return .object(["copied": .bool(true)])
                }
            }
        case "desktop_paste":
            guard let interactionId = object["interaction_id"]?.stringValue else { throw PluginError.invalidArguments("desktop_paste requires interaction_id") }
            let session = try sessions.get(interactionId)
            return try withUILock {
                try session.withLock {
                    guard ApplicationDriver.isActive(pid: session.record.pid) else {
                        throw PluginError(code: "BACKGROUND_SAFE_PASTE_UNAVAILABLE", message: "Paste requires the target application to already be foreground; silent mode will not activate it.", retryable: true, domain: "input")
                    }
                    try InputDriver.press(keys: ["command", "v"])
                    return .object(["pasted": .bool(true)])
                }
            }
        case "desktop_open_url":
            guard let url = object["url"]?.stringValue else { throw PluginError.invalidArguments("desktop_open_url requires url") }
            return try withUILock {
                try ApplicationDriver.openURL(url)
                return .object(["opened": .string(url)])
            }
        case "desktop_screenshot":
            let scope = object["scope"]?.stringValue ?? "display"
            var windowId = object["window_id"]?.intValue.map(UInt32.init)
            if windowId == nil, let interactionId = object["interaction_id"]?.stringValue {
                let session = try sessions.get(interactionId)
                windowId = ApplicationDriver.windows(pid: session.record.pid).first?.windowId
            }
            return try JSONValue.encode(ScreenshotDriver.capture(scope: scope, windowId: windowId, label: object["label"]?.stringValue))
        case "desktop_batch":
            return try withUILock { try executeBatch(object) }
        case "desktop_session_close":
            guard let interactionId = object["interaction_id"]?.stringValue else { throw PluginError.invalidArguments("desktop_session_close requires interaction_id") }
            return .object(["closed": .bool(sessions.remove(interactionId)), "interaction_id": .string(interactionId)])
        default:
            throw PluginError.unsupported("Unknown action \(action)")
        }
    }

    private func dispatch(_ request: RPCRequest) throws -> JSONValue {
        switch request.method {
        case "handshake":
            return try JSONValue.encode(HandshakeResult(
                protocolVersion: PluginManifest.current.protocolVersion,
                supportedProtocolVersions: [PluginManifest.current.protocolVersion],
                pluginId: PluginManifest.current.id,
                pluginVersion: PluginManifest.current.version,
                processId: getpid(),
                startedAt: startedAt
            ))
        case "manifest":
            return try JSONValue.encode(PluginManifest.current)
        case "health":
            return try JSONValue.encode(health())
        case "execute":
            guard let paramsValue = request.params else { throw PluginError.invalidArguments("execute requires params") }
            let params = try decode(ExecuteParams.self, from: paramsValue)
            return try execute(action: params.action, arguments: params.arguments)
        case "macos_browser_automation":
            guard let paramsValue = request.params else { throw PluginError.invalidArguments("macos_browser_automation requires params") }
            return try withBrowserLock { try browserAutomation.execute(params: paramsValue) }
        case "shutdown":
            shutdownRequested = true
            return .object(["shutting_down": .bool(true)])
        default:
            throw PluginError.unsupported("Unknown RPC method \(request.method)")
        }
    }


    private func withUILock<T>(_ body: () throws -> T) rethrows -> T {
        uiLock.lock()
        defer { uiLock.unlock() }
        return try body()
    }

    private func withBrowserLock<T>(_ body: () throws -> T) rethrows -> T {
        browserLock.lock()
        defer { browserLock.unlock() }
        return try body()
    }

    private func executeBatch(_ object: [String: JSONValue]) throws -> JSONValue {
        guard let steps = object["steps"]?.arrayValue else { throw PluginError.invalidArguments("desktop_batch requires steps") }
        guard !steps.isEmpty, steps.count <= 50 else { throw PluginError.invalidArguments("desktop_batch supports 1 through 50 steps") }
        let onError = object["on_error"]?.stringValue ?? "stop"
        guard ["stop", "continue"].contains(onError) else { throw PluginError.invalidArguments("on_error must be stop or continue") }
        var results: [JSONValue] = []
        var stoppedAt: Int?
        for (index, value) in steps.enumerated() {
            do {
                let step = try requireObject(value, name: "step")
                guard let action = step["action"]?.stringValue else { throw PluginError.invalidArguments("batch step requires action") }
                guard action != "desktop_batch" else { throw PluginError.invalidArguments("nested desktop_batch is not supported") }
                let result = try execute(action: action, arguments: step["arguments"] ?? .object([:]))
                results.append(.object(["index": .number(Double(index)), "action": .string(action), "ok": .bool(true), "result": result]))
            } catch let error as PluginError {
                results.append(.object(["index": .number(Double(index)), "ok": .bool(false), "error": (try? JSONValue.encode(error.payload)) ?? .string(error.description)]))
                if onError == "stop" { stoppedAt = index; break }
            }
        }
        return .object([
            "completed": .bool(stoppedAt == nil),
            "stopped_at": stoppedAt.map { .number(Double($0)) } ?? .null,
            "results": .array(results)
        ])
    }

    private func session(from object: [String: JSONValue]) throws -> DesktopSessionState {
        guard let id = object["interaction_id"]?.stringValue else { throw PluginError.invalidArguments("interaction_id is required") }
        return try sessions.get(id)
    }

    private func parseSelector(_ value: JSONValue?) throws -> ElementSelector {
        guard let object = value?.objectValue else { throw PluginError.invalidArguments("selector is required") }
        let selector = ElementSelector(
            ref: object["ref"]?.stringValue,
            role: object["role"]?.stringValue,
            title: object["title"]?.stringValue,
            identifier: object["identifier"]?.stringValue
        )
        guard selector.ref != nil || selector.role != nil || selector.title != nil || selector.identifier != nil else {
            throw PluginError.invalidArguments("selector requires ref, role, title, or identifier")
        }
        return selector
    }

    private func requireObject(_ value: JSONValue, name: String) throws -> [String: JSONValue] {
        guard let object = value.objectValue else { throw PluginError.invalidArguments("\(name) must be an object") }
        return object
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        let data = try JSONEncoder.repoHarness.encode(value)
        return try JSONDecoder.repoHarness.decode(type, from: data)
    }
}
