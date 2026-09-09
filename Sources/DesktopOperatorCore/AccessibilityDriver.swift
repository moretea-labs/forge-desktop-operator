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
        session.elementWindowRefs.removeAll(keepingCapacity: true)
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

    public func normalizedSnapshot(
        session: DesktopSessionState,
        maxDepth: Int,
        maxNodes: Int,
        includeValues: Bool,
        rootSelector: ElementSelector? = nil
    ) throws -> ComputerElementSnapshot {
        let legacy = try snapshot(
            session: session,
            maxDepth: maxDepth,
            maxNodes: maxNodes,
            includeValues: includeValues,
            includeActions: true,
            rootSelector: rootSelector
        )
        let record = session.record
        let root = Self.normalizeElement(
            legacy.root,
            record: record,
            snapshotRevision: legacy.snapshotRevision,
            inheritedWindowRef: nil
        )
        Self.recordElementWindowBindings(root, into: session)
        return ComputerElementSnapshot(
            protocolVersion: ComputerProviderProtocol.elementProtocolVersion,
            interactionId: record.interactionId,
            snapshotRevision: legacy.snapshotRevision,
            pid: record.pid,
            bundleIdentifier: record.bundleIdentifier,
            appName: record.appName,
            capturedAt: legacy.capturedAt,
            truncated: legacy.truncated,
            nodeCount: legacy.nodeCount,
            root: root
        )
    }

    static func normalizeElement(
        _ node: AXNode,
        record: DesktopSessionRecord,
        snapshotRevision: Int,
        inheritedWindowRef: String?
    ) -> ComputerElement {
        let windowRef = node.role == (kAXWindowRole as String) ? node.ref : inheritedWindowRef
        let actions = normalizedSemanticActions(
            rawActions: node.actions,
            role: node.role,
            expanded: node.expanded,
            selected: node.selected
        )
        let target = ComputerElementTarget(
            interactionId: record.interactionId,
            pid: record.pid,
            bundleIdentifier: record.bundleIdentifier,
            appName: record.appName,
            windowRef: windowRef,
            snapshotRevision: snapshotRevision
        )
        return ComputerElement(
            ref: node.ref,
            target: target,
            role: node.role,
            subrole: node.subrole,
            name: node.title ?? node.description ?? node.identifier,
            identifier: node.identifier,
            description: node.description,
            value: node.value,
            state: ComputerElementState(
                enabled: node.enabled,
                focused: node.focused,
                selected: node.selected,
                expanded: node.expanded
            ),
            bounds: node.frame,
            actions: actions,
            children: node.children.map { child in
                normalizeElement(
                    child,
                    record: record,
                    snapshotRevision: snapshotRevision,
                    inheritedWindowRef: windowRef
                )
            }
        )
    }

    private static func recordElementWindowBindings(_ element: ComputerElement, into session: DesktopSessionState) {
        if let windowRef = element.target.windowRef {
            session.elementWindowRefs[element.ref] = windowRef
        }
        for child in element.children {
            recordElementWindowBindings(child, into: session)
        }
    }

    static func normalizedSemanticActions(
        rawActions: [String],
        role: String?,
        expanded: Bool?,
        selected: Bool?
    ) -> [String] {
        var actions = Set<String>()
        let raw = Set(rawActions)
        if raw.contains(kAXPressAction as String) { actions.insert("invoke") }
        if raw.contains(kAXShowMenuAction as String) { actions.insert("show_menu") }
        if raw.contains(kAXPickAction as String) { actions.insert("select") }
        if raw.contains("AXOpen") || raw.contains("AXShowDefaultUI") { actions.insert("open") }
        if raw.contains("AXScrollDownByPage") { actions.insert("scroll_page_down") }
        if raw.contains("AXScrollUpByPage") { actions.insert("scroll_page_up") }
        if expanded != nil {
            actions.insert("expand")
            actions.insert("collapse")
            actions.insert("open")
        }
        if selected != nil { actions.insert("select") }
        if role == kAXTextFieldRole as String || role == kAXTextAreaRole as String || role == "AXComboBox" {
            actions.insert("set_value")
        }
        if role == kAXCheckBoxRole as String || role == kAXRadioButtonRole as String || role == "AXSwitch" {
            actions.insert("toggle")
        }
        if role != nil { actions.insert("focus") }
        return actions.sorted()
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
        if let disclosureValue = Self.disclosureValue(for: semanticAction) {
            return try setDisclosure(
                element: element,
                expanded: disclosureValue,
                semanticAction: semanticAction,
                snapshotRevision: session.record.snapshotRevision
            )
        }
        if semanticAction == "open", isOutlineRow(element), Self.isDisclosureSettable(element) {
            return try setDisclosure(
                element: element,
                expanded: true,
                semanticAction: semanticAction,
                snapshotRevision: session.record.snapshotRevision
            )
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
        if let fallbackAction = Self.openFallbackAction(
            semanticAction: semanticAction,
            primaryResult: result,
            availableActions: actionNames(of: element)
        ) {
            var fallbackResult = AXUIElementPerformAction(element, fallbackAction as CFString)
            if fallbackResult == .cannotComplete {
                Thread.sleep(forTimeInterval: 0.15)
                fallbackResult = AXUIElementPerformAction(element, fallbackAction as CFString)
            }
            if fallbackResult == .success {
                return .object([
                    "method": .string("AXShowDefaultUI_background"),
                    "semantic_action": .string(semanticAction),
                    "snapshot_revision": .number(Double(session.record.snapshotRevision))
                ])
            }
            result = fallbackResult
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

    static func openFallbackAction(semanticAction: String, primaryResult: AXError, availableActions: [String]) -> String? {
        guard semanticAction == "open", (primaryResult == .actionUnsupported || primaryResult == .attributeUnsupported) else { return nil }
        return availableActions.contains("AXShowDefaultUI") ? "AXShowDefaultUI" : nil
    }

    private func isOutlineRow(_ element: AXUIElement) -> Bool {
        stringAttribute(element, kAXRoleAttribute as CFString) == kAXRowRole as String
    }

    private static func isDisclosureSettable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(
            element,
            kAXDisclosingAttribute as CFString,
            &settable
        )
        return result == .success && settable.boolValue
    }

    static func disclosureValue(for semanticAction: String) -> Bool? {
        switch semanticAction {
        case "expand": return true
        case "collapse": return false
        default: return nil
        }
    }

    private func setDisclosure(
        element: AXUIElement,
        expanded: Bool,
        semanticAction: String,
        snapshotRevision: Int
    ) throws -> JSONValue {
        var settable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(
            element,
            kAXDisclosingAttribute as CFString,
            &settable
        )
        guard settableResult == .success, settable.boolValue else {
            throw PluginError(
                code: "AX_DISCLOSING_NOT_SETTABLE",
                message: "Selected Accessibility element does not allow AXDisclosing to be changed.",
                retryable: settableResult == .cannotComplete,
                domain: "accessibility"
            )
        }

        let value: CFBoolean = expanded ? kCFBooleanTrue : kCFBooleanFalse
        var result = AXUIElementSetAttributeValue(
            element,
            kAXDisclosingAttribute as CFString,
            value
        )
        if result == .cannotComplete {
            Thread.sleep(forTimeInterval: 0.15)
            result = AXUIElementSetAttributeValue(
                element,
                kAXDisclosingAttribute as CFString,
                value
            )
        }
        guard result == .success else {
            throw PluginError(
                code: "AX_DISCLOSING_SET_FAILED",
                message: "Could not set AXDisclosing; Accessibility returned code \(result.rawValue).",
                retryable: result == .cannotComplete,
                domain: "accessibility"
            )
        }
        return .object([
            "method": .string("AXDisclosing_set"),
            "semantic_action": .string(semanticAction),
            "expanded": .bool(expanded),
            "snapshot_revision": .number(Double(snapshotRevision))
        ])
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
            throw PluginError.invalidArguments("desktop_press semantic_action must be press, show_menu, pick, open, confirm, expand, collapse, scroll_down_page, or scroll_up_page")
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


    static func rowSelectionRange(rowCount: Int, startIndex: Int, endIndex: Int?) throws -> ClosedRange<Int> {
        guard rowCount > 0 else {
            throw PluginError(code: "AX_SELECTED_ROWS_UNAVAILABLE", message: "Selected Accessibility element does not expose rows.", retryable: false, domain: "accessibility")
        }
        let resolvedEnd = endIndex ?? (rowCount - 1)
        guard startIndex >= 0, startIndex < rowCount, resolvedEnd >= startIndex, resolvedEnd < rowCount else {
            throw PluginError.invalidArguments(
                "desktop_select_rows range must be inside 0..<\(rowCount) and end_index must not precede start_index"
            )
        }
        return startIndex...resolvedEnd
    }

    public func selectRows(
        session: DesktopSessionState,
        selector: ElementSelector,
        startIndex: Int,
        endIndex: Int? = nil
    ) throws -> JSONValue {
        let element = try resolveElement(session: session, selector: selector)
        prepare(element)
        let rows = children(of: element).filter {
            stringAttribute($0, kAXRoleAttribute as CFString) == kAXRowRole as String
        }
        guard !rows.isEmpty else {
            throw PluginError(
                code: "AX_SELECTED_ROWS_UNAVAILABLE",
                message: "Selected Accessibility element does not expose rows.",
                retryable: false,
                domain: "accessibility"
            )
        }
        let selectionRange = try Self.rowSelectionRange(
            rowCount: rows.count,
            startIndex: startIndex,
            endIndex: endIndex
        )
        let resolvedEnd = selectionRange.upperBound

        var settable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(
            element,
            kAXSelectedRowsAttribute as CFString,
            &settable
        )
        guard settableResult == .success, settable.boolValue else {
            throw PluginError(
                code: "AX_SELECTED_ROWS_NOT_SETTABLE",
                message: "Selected Accessibility element does not allow AXSelectedRows to be changed.",
                retryable: false,
                domain: "accessibility"
            )
        }

        let selectedRows = Array(rows[selectionRange])
        let setResult = AXUIElementSetAttributeValue(
            element,
            kAXSelectedRowsAttribute as CFString,
            selectedRows as CFArray
        )
        guard setResult == .success else {
            throw PluginError(
                code: "AX_SELECTED_ROWS_SET_FAILED",
                message: "Could not set AXSelectedRows; Accessibility returned code \(setResult.rawValue).",
                retryable: setResult == .cannotComplete,
                domain: "accessibility"
            )
        }

        return .object([
            "row_count": .number(Double(rows.count)),
            "selected_count": .number(Double(selectedRows.count)),
            "start_index": .number(Double(startIndex)),
            "end_index": .number(Double(resolvedEnd)),
            "snapshot_revision": .number(Double(session.record.snapshotRevision))
        ])
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

    public func performElementAction(
        session: DesktopSessionState,
        ref: String,
        target: ComputerElementTarget,
        action: String,
        value: JSONValue?
    ) throws -> JSONValue {
        let snapshotRevision = target.snapshotRevision
        let element = try resolveObservedElement(
            session: session,
            ref: ref,
            target: target
        )
        prepare(element)
        let supported = Set(Self.normalizedSemanticActions(
            rawActions: actionNames(of: element),
            role: stringAttribute(element, kAXRoleAttribute as CFString),
            expanded: boolAttribute(element, kAXDisclosingAttribute as CFString),
            selected: boolAttribute(element, kAXSelectedAttribute as CFString)
        ))
        guard supported.contains(action) else {
            throw PluginError(
                code: "COMPUTER_ELEMENT_ACTION_UNSUPPORTED",
                message: "Element \(ref) does not support semantic action \(action) in snapshot \(snapshotRevision)",
                retryable: false,
                domain: "accessibility"
            )
        }

        switch action {
        case "invoke", "toggle":
            return try performObservedAXAction(
                element: element,
                axAction: kAXPressAction as CFString,
                method: "AXPress_background",
                semanticAction: action,
                ref: ref,
                snapshotRevision: snapshotRevision
            )
        case "show_menu":
            return try performObservedAXAction(
                element: element,
                axAction: kAXShowMenuAction as CFString,
                method: "AXShowMenu_background",
                semanticAction: action,
                ref: ref,
                snapshotRevision: snapshotRevision
            )
        case "focus":
            return try setObservedAttribute(
                element: element,
                attribute: kAXFocusedAttribute as CFString,
                value: kCFBooleanTrue,
                method: "AXFocused_set",
                semanticAction: action,
                ref: ref,
                snapshotRevision: snapshotRevision
            )
        case "set_value":
            guard let value else {
                throw PluginError.invalidArguments("computer.element.action.v2 set_value requires value")
            }
            let nativeValue = try Self.nativeAttributeValue(value)
            return try setObservedAttribute(
                element: element,
                attribute: kAXValueAttribute as CFString,
                value: nativeValue,
                method: "AXValue_set",
                semanticAction: action,
                ref: ref,
                snapshotRevision: snapshotRevision
            )
        case "expand":
            var payload = try setDisclosure(
                element: element,
                expanded: true,
                semanticAction: action,
                snapshotRevision: snapshotRevision
            ).objectValue ?? [:]
            payload["ref"] = .string(ref)
            return .object(payload)
        case "collapse":
            var payload = try setDisclosure(
                element: element,
                expanded: false,
                semanticAction: action,
                snapshotRevision: snapshotRevision
            ).objectValue ?? [:]
            payload["ref"] = .string(ref)
            return .object(payload)
        case "select":
            var settable = DarwinBoolean(false)
            let settableResult = AXUIElementIsAttributeSettable(
                element,
                kAXSelectedAttribute as CFString,
                &settable
            )
            if settableResult == .success, settable.boolValue {
                return try setObservedAttribute(
                    element: element,
                    attribute: kAXSelectedAttribute as CFString,
                    value: kCFBooleanTrue,
                    method: "AXSelected_set",
                    semanticAction: action,
                    ref: ref,
                    snapshotRevision: snapshotRevision
                )
            }
            return try performObservedAXAction(
                element: element,
                axAction: kAXPickAction as CFString,
                method: "AXPick_background",
                semanticAction: action,
                ref: ref,
                snapshotRevision: snapshotRevision
            )
        case "open":
            if isOutlineRow(element), Self.isDisclosureSettable(element) {
                var payload = try setDisclosure(
                    element: element,
                    expanded: true,
                    semanticAction: action,
                    snapshotRevision: snapshotRevision
                ).objectValue ?? [:]
                payload["ref"] = .string(ref)
                return .object(payload)
            }
            var result = AXUIElementPerformAction(element, "AXOpen" as CFString)
            if result == .cannotComplete {
                Thread.sleep(forTimeInterval: 0.15)
                result = AXUIElementPerformAction(element, "AXOpen" as CFString)
            }
            if result == .success {
                return .object([
                    "method": .string("AXOpen_background"),
                    "semantic_action": .string(action),
                    "ref": .string(ref),
                    "snapshot_revision": .number(Double(snapshotRevision))
                ])
            }
            if (result == .actionUnsupported || result == .attributeUnsupported), actionNames(of: element).contains("AXShowDefaultUI") {
                return try performObservedAXAction(
                    element: element,
                    axAction: "AXShowDefaultUI" as CFString,
                    method: "AXShowDefaultUI_background",
                    semanticAction: action,
                    ref: ref,
                    snapshotRevision: snapshotRevision
                )
            }
            throw PluginError(
                code: "COMPUTER_ELEMENT_ACTION_FAILED",
                message: "AXOpen failed with code \(result.rawValue)",
                retryable: result == .cannotComplete,
                domain: "accessibility"
            )
        case "scroll_page_down":
            return try performObservedAXAction(
                element: element,
                axAction: "AXScrollDownByPage" as CFString,
                method: "AXScrollDownByPage_background",
                semanticAction: action,
                ref: ref,
                snapshotRevision: snapshotRevision
            )
        case "scroll_page_up":
            return try performObservedAXAction(
                element: element,
                axAction: "AXScrollUpByPage" as CFString,
                method: "AXScrollUpByPage_background",
                semanticAction: action,
                ref: ref,
                snapshotRevision: snapshotRevision
            )
        default:
            throw PluginError.invalidArguments("Unsupported computer element semantic action: \(action)")
        }
    }

    static func validateObservedTargetIdentity(
        session: DesktopSessionState,
        ref: String,
        target: ComputerElementTarget
    ) throws {
        let record = session.record
        guard target.interactionId == record.interactionId,
              target.pid == record.pid,
              target.bundleIdentifier == record.bundleIdentifier,
              target.appName == record.appName else {
            throw PluginError(
                code: "COMPUTER_ELEMENT_TARGET_MISMATCH",
                message: "Element target no longer matches the exact application binding that produced the observation.",
                retryable: true,
                domain: "accessibility"
            )
        }
        guard target.snapshotRevision > 0, target.snapshotRevision == record.snapshotRevision else {
            throw PluginError(
                code: "COMPUTER_ELEMENT_OBSERVATION_STALE",
                message: "Element ref \(ref) belongs to snapshot \(target.snapshotRevision), but current snapshot is \(record.snapshotRevision). Re-observe before acting.",
                retryable: true,
                domain: "accessibility"
            )
        }
        guard ref.hasPrefix("ax_\(target.snapshotRevision)_") else {
            throw PluginError(
                code: "COMPUTER_ELEMENT_OBSERVATION_STALE",
                message: "Element ref \(ref) does not belong to snapshot \(target.snapshotRevision).",
                retryable: true,
                domain: "accessibility"
            )
        }
        guard session.elementWindowRefs[ref] == target.windowRef else {
            throw PluginError(
                code: "COMPUTER_ELEMENT_TARGET_MISMATCH",
                message: "Element ref \(ref) no longer matches the observed window binding.",
                retryable: true,
                domain: "accessibility"
            )
        }
        if let windowRef = target.windowRef {
            guard windowRef.hasPrefix("ax_\(target.snapshotRevision)_"), session.elements[windowRef] != nil else {
                throw PluginError(
                    code: "COMPUTER_ELEMENT_TARGET_MISMATCH",
                    message: "Observed window ref \(windowRef) is not present in the exact current observation.",
                    retryable: true,
                    domain: "accessibility"
                )
            }
        }
    }

    private func resolveObservedElement(
        session: DesktopSessionState,
        ref: String,
        target: ComputerElementTarget
    ) throws -> AXUIElement {
        try Self.validateObservedTargetIdentity(session: session, ref: ref, target: target)
        guard let element = session.elements[ref] else {
            throw PluginError(
                code: "COMPUTER_ELEMENT_OBSERVATION_STALE",
                message: "Element ref \(ref) is not present in the exact current observation. Re-observe before acting.",
                retryable: true,
                domain: "accessibility"
            )
        }
        return element
    }

    private func performObservedAXAction(
        element: AXUIElement,
        axAction: CFString,
        method: String,
        semanticAction: String,
        ref: String,
        snapshotRevision: Int
    ) throws -> JSONValue {
        var result = AXUIElementPerformAction(element, axAction)
        if result == .cannotComplete {
            Thread.sleep(forTimeInterval: 0.15)
            result = AXUIElementPerformAction(element, axAction)
        }
        guard result == .success else {
            throw PluginError(
                code: "COMPUTER_ELEMENT_ACTION_FAILED",
                message: "\(axAction as String) failed with code \(result.rawValue)",
                retryable: result == .cannotComplete,
                domain: "accessibility"
            )
        }
        return .object([
            "method": .string(method),
            "semantic_action": .string(semanticAction),
            "ref": .string(ref),
            "snapshot_revision": .number(Double(snapshotRevision))
        ])
    }

    private func setObservedAttribute(
        element: AXUIElement,
        attribute: CFString,
        value: CFTypeRef,
        method: String,
        semanticAction: String,
        ref: String,
        snapshotRevision: Int
    ) throws -> JSONValue {
        var settable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(element, attribute, &settable)
        guard settableResult == .success, settable.boolValue else {
            throw PluginError(
                code: "COMPUTER_ELEMENT_ATTRIBUTE_NOT_SETTABLE",
                message: "Accessibility attribute \(attribute as String) is not settable for element \(ref)",
                retryable: settableResult == .cannotComplete,
                domain: "accessibility"
            )
        }
        var result = AXUIElementSetAttributeValue(element, attribute, value)
        if result == .cannotComplete {
            Thread.sleep(forTimeInterval: 0.15)
            result = AXUIElementSetAttributeValue(element, attribute, value)
        }
        guard result == .success else {
            throw PluginError(
                code: "COMPUTER_ELEMENT_ATTRIBUTE_SET_FAILED",
                message: "Accessibility attribute \(attribute as String) failed with code \(result.rawValue)",
                retryable: result == .cannotComplete,
                domain: "accessibility"
            )
        }
        return .object([
            "method": .string(method),
            "semantic_action": .string(semanticAction),
            "ref": .string(ref),
            "snapshot_revision": .number(Double(snapshotRevision))
        ])
    }

    private static func nativeAttributeValue(_ value: JSONValue) throws -> CFTypeRef {
        switch value {
        case .string(let string): return string as CFString
        case .number(let number): return NSNumber(value: number)
        case .bool(let bool): return bool ? kCFBooleanTrue : kCFBooleanFalse
        case .array(let values):
            let strings = try values.map { item -> String in
                guard case .string(let string) = item else {
                    throw PluginError.invalidArguments("set_value arrays may contain only strings")
                }
                return string
            }
            return strings as CFArray
        case .null, .object:
            throw PluginError.invalidArguments("set_value supports string, number, bool, or string-array values")
        }
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
            selected: boolAttribute(element, kAXSelectedAttribute as CFString),
            expanded: boolAttribute(element, kAXDisclosingAttribute as CFString),
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
