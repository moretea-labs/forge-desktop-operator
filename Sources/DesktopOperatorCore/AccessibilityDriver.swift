@preconcurrency import ApplicationServices
import Foundation

public final class AccessibilityDriver {
    private struct VisitedElements {
        private var buckets: [CFHashCode: [AXUIElement]] = [:]

        mutating func insert(_ element: AXUIElement) -> Bool {
            let hash = CFHash(element)
            if buckets[hash]?.contains(where: { CFEqual($0, element) }) == true { return false }
            buckets[hash, default: []].append(element)
            return true
        }
    }

    public init() {}

    public var trusted: Bool { AXIsProcessTrusted() }

    public static func requestTrustPrompt() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    public func snapshot(
        session: DesktopSessionState,
        maxDepth: Int,
        maxNodes: Int,
        includeValues: Bool,
        includeActions: Bool = true,
        rootSelector: ElementSelector? = nil
    ) throws -> AccessibilitySnapshot {
        guard trusted else {
            let permission = DesktopPermissions.accessibility(granted: false)
            throw PluginError(
                code: "ACCESSIBILITY_NOT_TRUSTED",
                message: "Grant Accessibility access to Forge Desktop Operator (com.moretea.forge.desktop-operator) in System Settings > Privacy & Security > Accessibility",
                retryable: true,
                domain: "tcc",
                details: try? JSONValue.encode(permission)
            )
        }
        let applicationRoot = AXUIElementCreateApplication(session.record.pid)
        prepare(applicationRoot)
        session.lastRootElement = applicationRoot
        let root = if let rootSelector {
            try resolveElement(session: session, selector: rootSelector)
        } else {
            applicationRoot
        }
        session.elements.removeAll(keepingCapacity: true)
        session.record.snapshotRevision += 1
        session.record.lastObservedAt = Date()

        var counter = 0
        var truncated = false
        var visited = VisitedElements()
        _ = visited.insert(root)
        let node = buildNode(
            element: root,
            session: session,
            revision: session.record.snapshotRevision,
            depth: 0,
            maxDepth: max(0, min(maxDepth, 30)),
            maxNodes: max(1, min(maxNodes, 5_000)),
            includeValues: includeValues,
            includeActions: includeActions,
            includeApplicationExtras: rootSelector == nil,
            counter: &counter,
            truncated: &truncated,
            visited: &visited
        )
        return AccessibilitySnapshot(
            interactionId: session.record.interactionId,
            snapshotRevision: session.record.snapshotRevision,
            capturedAt: Date(),
            truncated: truncated,
            nodeCount: counter,
            root: node
        )
    }

    public func press(
        session: DesktopSessionState,
        selector: ElementSelector,
        coordinateFallback: Bool,
        forceCoordinate: Bool = false,
        semanticAction: String = "press"
    ) throws -> JSONValue {
        let element = try resolveElement(session: session, selector: selector)
        prepare(element)
        if forceCoordinate {
            guard ApplicationDriver.isActive(pid: session.record.pid) else {
                throw PluginError(
                    code: "FOREGROUND_COORDINATE_INPUT_REQUIRES_ACTIVE_APP",
                    message: "Explicit coordinate input is allowed only while the target application is already foreground.",
                    retryable: true,
                    domain: "accessibility"
                )
            }
            guard let elementFrame = frame(of: element) else {
                throw PluginError(code: "COORDINATE_PRESS_FRAME_INVALID", message: "Selected Accessibility element does not expose a clickable frame", retryable: false, domain: "accessibility")
            }
            let point = try Self.coordinateClickPoint(frame: elementFrame, displayBounds: Self.activeDisplayBounds())
            try InputDriver.click(x: point.x, y: point.y)
            return .object([
                "method": .string("CGEvent_click_explicit_foreground"),
                "x": .number(point.x),
                "y": .number(point.y),
                "snapshot_revision": .number(Double(session.record.snapshotRevision))
            ])
        }
        let semantic = try Self.semanticAccessibilityAction(semanticAction)
        var result = AXUIElementPerformAction(element, semantic.action)
        if result == .cannotComplete {
            Thread.sleep(forTimeInterval: 0.15)
            result = AXUIElementPerformAction(element, semantic.action)
        }
        if result == .success {
            return .object([
                "method": .string(semantic.method),
                "semantic_action": .string(semanticAction),
                "snapshot_revision": .number(Double(session.record.snapshotRevision))
            ])
        }
        if semantic.isScroll, result == .actionUnsupported {
            throw PluginError(
                code: "AX_SCROLL_ACTION_UNSUPPORTED",
                message: "Selected Accessibility element does not support \(semantic.action as String).",
                retryable: false,
                domain: "accessibility"
            )
        }
        if semantic.isScroll {
            throw PluginError(
                code: "AX_SCROLL_FAILED",
                message: "\(semantic.action as String) failed with code \(result.rawValue)",
                retryable: result == .cannotComplete,
                domain: "accessibility"
            )
        }
        throw PluginError(
            code: coordinateFallback ? "BACKGROUND_SAFE_COORDINATE_FALLBACK_DISABLED" : "AX_PRESS_FAILED",
            message: coordinateFallback
                ? "AXPress failed and silent mode refuses coordinate fallback because it can steal the pointer or foreground."
                : "AXPress failed with code \(result.rawValue)",
            retryable: result == .cannotComplete,
            domain: "accessibility"
        )
    }

    static func semanticAccessibilityAction(_ semanticAction: String) throws -> (action: CFString, method: String, isScroll: Bool) {
        switch semanticAction {
        case "press":
            return (kAXPressAction as CFString, "AXPress_background", false)
        case "show_menu":
            return (kAXShowMenuAction as CFString, "AXShowMenu_background", false)
        case "pick":
            return (kAXPickAction as CFString, "AXPick_background", false)
        case "open":
            return ("AXOpen" as CFString, "AXOpen_background", false)
        case "confirm":
            return ("AXConfirm" as CFString, "AXConfirm_background", false)
        case "scroll_down_page":
            return ("AXScrollDownByPage" as CFString, "AXScrollDownByPage_background", true)
        case "scroll_up_page":
            return ("AXScrollUpByPage" as CFString, "AXScrollUpByPage_background", true)
        default:
            throw PluginError.invalidArguments("desktop_press semantic_action must be press, show_menu, pick, open, confirm, scroll_down_page, or scroll_up_page")
        }
    }

    static func coordinateFallbackSelector(_ selector: ElementSelector, applicationWasActive: Bool) throws -> ElementSelector {
        if applicationWasActive { return selector }
        if selector.title != nil || selector.identifier != nil {
            return ElementSelector(role: selector.role, title: selector.title, identifier: selector.identifier)
        }
        throw PluginError(
            code: "COORDINATE_PRESS_REQUIRES_FRESH_SNAPSHOT",
            message: "The application was activated after this selector was observed; re-observe and retry before using physical coordinate fallback",
            retryable: true,
            domain: "accessibility"
        )
    }

    static func coordinateClickPoint(frame: DesktopFrame, displayBounds: [DesktopFrame]) throws -> (x: Double, y: Double) {
        let values = [frame.x, frame.y, frame.width, frame.height]
        guard values.allSatisfy({ $0.isFinite }), frame.width >= 1, frame.height >= 1 else {
            throw PluginError(code: "COORDINATE_PRESS_FRAME_INVALID", message: "Selected Accessibility element has an invalid clickable frame", retryable: false, domain: "accessibility")
        }
        let x = frame.x + frame.width / 2
        let y = frame.y + frame.height / 2
        guard displayBounds.contains(where: { bounds in
            x >= bounds.x && x <= bounds.x + bounds.width && y >= bounds.y && y <= bounds.y + bounds.height
        }) else {
            throw PluginError(code: "COORDINATE_PRESS_OFFSCREEN", message: "Selected Accessibility element is outside active displays", retryable: true, domain: "accessibility")
        }
        return (x, y)
    }

    private static func activeDisplayBounds() -> [DesktopFrame] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map { display in
            let bounds = CGDisplayBounds(display)
            return DesktopFrame(x: bounds.origin.x, y: bounds.origin.y, width: bounds.width, height: bounds.height)
        }
    }

    public func typeText(session: DesktopSessionState, selector: ElementSelector, text: String, replaceExisting: Bool) throws -> JSONValue {
        let element = try resolveElement(session: session, selector: selector)
        prepare(element)
        let nextValue: String
        if replaceExisting {
            nextValue = text
        } else {
            var currentValue: CFTypeRef?
            let readResult = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &currentValue)
            guard readResult == .success else {
                throw PluginError(
                    code: "BACKGROUND_SAFE_TEXT_INPUT_UNAVAILABLE",
                    message: "Silent text append requires a readable Accessibility value; synthetic keyboard input is disabled.",
                    retryable: readResult == .cannotComplete,
                    domain: "accessibility"
                )
            }
            nextValue = (currentValue as? String ?? "") + text
        }
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, nextValue as CFString)
        guard result == .success else {
            throw PluginError(
                code: "BACKGROUND_SAFE_TEXT_INPUT_UNAVAILABLE",
                message: "The selected element does not accept background AXValue updates; synthetic keyboard input and foreground activation are disabled.",
                retryable: result == .cannotComplete,
                domain: "accessibility"
            )
        }
        return .object([
            "method": .string("AXValue_background"),
            "characters": .number(Double(text.count))
        ])
    }

    public func resolveElement(session: DesktopSessionState, selector: ElementSelector) throws -> AXUIElement {
        if let ref = selector.ref, let element = session.elements[ref] {
            return element
        }
        let root = session.lastRootElement ?? AXUIElementCreateApplication(session.record.pid)
        var visited = 0
        var seen = VisitedElements()
        _ = seen.insert(root)
        if let match = find(
            element: root,
            selector: selector,
            visited: &visited,
            limit: 5_000,
            seen: &seen,
            includeApplicationExtras: true
        ) {
            return match
        }
        throw PluginError(
            code: "ELEMENT_NOT_FOUND",
            message: "No Accessibility element matched the selector",
            retryable: true,
            domain: "accessibility",
            details: try? JSONValue.encode(selector)
        )
    }

    private func find(
        element: AXUIElement,
        selector: ElementSelector,
        visited: inout Int,
        limit: Int,
        seen: inout VisitedElements,
        includeApplicationExtras: Bool = false
    ) -> AXUIElement? {
        guard visited < limit else { return nil }
        visited += 1
        let matchesRole = selector.role == nil || stringAttribute(element, kAXRoleAttribute as CFString) == selector.role
        let matchesTitle = selector.title == nil || stringAttribute(element, kAXTitleAttribute as CFString) == selector.title
        let matchesIdentifier = selector.identifier == nil || stringAttribute(element, kAXIdentifierAttribute as CFString) == selector.identifier
        if matchesRole && matchesTitle && matchesIdentifier && (selector.role != nil || selector.title != nil || selector.identifier != nil) {
            return element
        }
        for child in children(of: element, includeApplicationExtras: includeApplicationExtras) {
            guard seen.insert(child) else { continue }
            if let found = find(
                element: child,
                selector: selector,
                visited: &visited,
                limit: limit,
                seen: &seen
            ) { return found }
        }
        return nil
    }

    private func buildNode(
        element: AXUIElement,
        session: DesktopSessionState,
        revision: Int,
        depth: Int,
        maxDepth: Int,
        maxNodes: Int,
        includeValues: Bool,
        includeActions: Bool,
        includeApplicationExtras: Bool = false,
        counter: inout Int,
        truncated: inout Bool,
        visited: inout VisitedElements
    ) -> AXNode {
        counter += 1
        let ref = "ax_\(revision)_\(counter)"
        session.elements[ref] = element
        let role = stringAttribute(element, kAXRoleAttribute as CFString)
        let secure = role == "AXSecureTextField"
        var childNodes: [AXNode] = []
        let childElements = children(of: element, includeApplicationExtras: includeApplicationExtras)
        if depth < maxDepth && counter < maxNodes {
            for child in childElements {
                guard counter < maxNodes else { truncated = true; break }
                guard visited.insert(child) else { continue }
                childNodes.append(buildNode(
                    element: child,
                    session: session,
                    revision: revision,
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    maxNodes: maxNodes,
                    includeValues: includeValues,
                    includeActions: includeActions,
                    counter: &counter,
                    truncated: &truncated,
                    visited: &visited
                ))
            }
        } else if !childElements.isEmpty {
            truncated = true
        }
        return AXNode(
            ref: ref,
            role: role,
            subrole: stringAttribute(element, kAXSubroleAttribute as CFString),
            title: stringAttribute(element, kAXTitleAttribute as CFString),
            identifier: stringAttribute(element, kAXIdentifierAttribute as CFString),
            description: stringAttribute(element, kAXDescriptionAttribute as CFString),
            value: includeValues && !secure ? jsonAttribute(element, kAXValueAttribute as CFString) : nil,
            enabled: boolAttribute(element, kAXEnabledAttribute as CFString),
            focused: boolAttribute(element, kAXFocusedAttribute as CFString),
            frame: frame(of: element),
            actions: includeActions ? actionNames(of: element) : [],
            children: childNodes
        )
    }

    private func prepare(_ element: AXUIElement) {
        _ = AXUIElementSetMessagingTimeout(element, 0.2)
    }

    private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        prepare(element)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    private func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
        attribute(element, name) as? String
    }

    private func boolAttribute(_ element: AXUIElement, _ name: CFString) -> Bool? {
        attribute(element, name) as? Bool
    }

    private func jsonAttribute(_ element: AXUIElement, _ name: CFString) -> JSONValue? {
        guard let value = attribute(element, name) else { return nil }
        if let string = value as? String { return .string(string) }
        if let number = value as? NSNumber { return .number(number.doubleValue) }
        if let array = value as? [String] { return .array(array.map(JSONValue.string)) }
        return .string(String(describing: value))
    }

    private func children(of element: AXUIElement, includeApplicationExtras: Bool = false) -> [AXUIElement] {
        let directChildren = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
        guard includeApplicationExtras else { return directChildren }

        let windows = attribute(element, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []
        let focusedWindow = elementAttribute(element, kAXFocusedWindowAttribute as CFString)
        let mainWindow = elementAttribute(element, kAXMainWindowAttribute as CFString)
        let menuBar = elementAttribute(element, kAXMenuBarAttribute as CFString)
        let focusedElement = elementAttribute(element, kAXFocusedUIElementAttribute as CFString)
        return Self.mergeApplicationTraversalElements(
            children: directChildren,
            windows: windows,
            focusedWindow: focusedWindow,
            mainWindow: mainWindow,
            menuBar: menuBar,
            focusedElement: focusedElement
        )
    }

    static func mergeApplicationTraversalElements(
        children: [AXUIElement],
        windows: [AXUIElement],
        focusedWindow: AXUIElement?,
        mainWindow: AXUIElement?,
        menuBar: AXUIElement?,
        focusedElement: AXUIElement?
    ) -> [AXUIElement] {
        var result: [AXUIElement] = []
        func appendUnique(_ element: AXUIElement?) {
            guard let element, !result.contains(where: { CFEqual($0, element) }) else { return }
            result.append(element)
        }

        children.forEach { appendUnique($0) }
        appendUnique(focusedWindow)
        appendUnique(mainWindow)
        windows.forEach { appendUnique($0) }
        appendUnique(menuBar)
        appendUnique(focusedElement)
        return result
    }

    private func elementAttribute(_ element: AXUIElement, _ name: CFString) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func actionNames(of element: AXUIElement) -> [String] {
        prepare(element)
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    private func frame(of element: AXUIElement) -> DesktopFrame? {
        guard let positionValue = attribute(element, kAXPositionAttribute as CFString),
              let sizeValue = attribute(element, kAXSizeAttribute as CFString),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return DesktopFrame(x: point.x, y: point.y, width: size.width, height: size.height)
    }
}
