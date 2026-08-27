import ApplicationServices
import Foundation

public enum InputDriver {
    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "enter": 36,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126
    ]

    public static func click(x: Double, y: Double) throws {
        try click(x: x, y: y, button: "left", clickCount: 1)
    }

    public static func move(x: Double, y: Double, steps: Int = 1) throws {
        let target = CGPoint(x: x, y: y)
        let start = CGEvent(source: nil)?.location ?? target
        let count = max(1, min(steps, 100))
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw PluginError(code: "INPUT_EVENT_CREATE_FAILED", message: "Could not create mouse event source", retryable: true, domain: "input")
        }
        for index in 1...count {
            let fraction = Double(index) / Double(count)
            let point = CGPoint(x: start.x + (target.x - start.x) * fraction, y: start.y + (target.y - start.y) * fraction)
            guard let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
                throw PluginError(code: "INPUT_EVENT_CREATE_FAILED", message: "Could not create mouse move event", retryable: true, domain: "input")
            }
            event.post(tap: .cghidEventTap)
        }
    }

    public static func click(x: Double, y: Double, button: String, clickCount: Int) throws {
        let (mouseButton, downType, upType, _) = try mouseTypes(button)
        let point = CGPoint(x: x, y: y)
        try move(x: x, y: y)
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw PluginError(code: "INPUT_EVENT_CREATE_FAILED", message: "Could not create mouse event source", retryable: true, domain: "input")
        }
        for index in 1...max(1, min(clickCount, 3)) {
            guard let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: mouseButton),
                  let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: mouseButton) else {
                throw PluginError(code: "INPUT_EVENT_CREATE_FAILED", message: "Could not create mouse click events", retryable: true, domain: "input")
            }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            down.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.03)
            up.post(tap: .cghidEventTap)
        }
    }

    public static func wheel(x: Double, y: Double, deltaX: Double, deltaY: Double) throws {
        try move(x: x, y: y)
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(deltaY.rounded()), wheel2: Int32(deltaX.rounded()), wheel3: 0) else {
            throw PluginError(code: "INPUT_EVENT_CREATE_FAILED", message: "Could not create scroll event", retryable: true, domain: "input")
        }
        event.post(tap: .cghidEventTap)
    }

    public static func drag(fromX: Double, fromY: Double, toX: Double, toY: Double, button: String, steps: Int) throws {
        let (mouseButton, downType, upType, dragType) = try mouseTypes(button)
        try move(x: fromX, y: fromY)
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: CGPoint(x: fromX, y: fromY), mouseButton: mouseButton) else {
            throw PluginError(code: "INPUT_EVENT_CREATE_FAILED", message: "Could not create drag events", retryable: true, domain: "input")
        }
        down.post(tap: .cghidEventTap)
        let count = max(1, min(steps, 100))
        for index in 1...count {
            let fraction = Double(index) / Double(count)
            let point = CGPoint(x: fromX + (toX - fromX) * fraction, y: fromY + (toY - fromY) * fraction)
            guard let drag = CGEvent(mouseEventSource: source, mouseType: dragType, mouseCursorPosition: point, mouseButton: mouseButton) else {
                throw PluginError(code: "INPUT_EVENT_CREATE_FAILED", message: "Could not create drag move event", retryable: true, domain: "input")
            }
            drag.post(tap: .cghidEventTap)
        }
        guard let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: CGPoint(x: toX, y: toY), mouseButton: mouseButton) else {
            throw PluginError(code: "INPUT_EVENT_CREATE_FAILED", message: "Could not create drag release event", retryable: true, domain: "input")
        }
        up.post(tap: .cghidEventTap)
    }

    private static func mouseTypes(_ button: String) throws -> (CGMouseButton, CGEventType, CGEventType, CGEventType) {
        switch button.lowercased() {
        case "left": return (.left, .leftMouseDown, .leftMouseUp, .leftMouseDragged)
        case "right": return (.right, .rightMouseDown, .rightMouseUp, .rightMouseDragged)
        case "middle": return (.center, .otherMouseDown, .otherMouseUp, .otherMouseDragged)
        default: throw PluginError.invalidArguments("Unsupported mouse button: \(button)")
        }
    }

    public static func press(keys: [String]) throws {
        let normalized = keys.map { key in
            switch key.lowercased() {
            case "arrowleft": return "left"
            case "arrowright": return "right"
            case "arrowup": return "up"
            case "arrowdown": return "down"
            default: return key.lowercased()
            }
        }
        guard let keyName = normalized.last(where: { !["cmd", "command", "meta", "shift", "option", "alt", "control", "ctrl"].contains($0) }),
              let keyCode = keyCodes[keyName] else {
            throw PluginError.invalidArguments("Unsupported key combination: \(keys.joined(separator: "+"))")
        }
        var flags: CGEventFlags = []
        if normalized.contains(where: { ["cmd", "command", "meta"].contains($0) }) { flags.insert(.maskCommand) }
        if normalized.contains("shift") { flags.insert(.maskShift) }
        if normalized.contains(where: { ["option", "alt"].contains($0) }) { flags.insert(.maskAlternate) }
        if normalized.contains(where: { ["control", "ctrl"].contains($0) }) { flags.insert(.maskControl) }

        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw PluginError(code: "INPUT_EVENT_CREATE_FAILED", message: "Could not create keyboard events", retryable: true, domain: "input")
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    public static func typeUnicode(_ text: String, replaceExisting: Bool) throws {
        if replaceExisting {
            try press(keys: ["cmd", "a"])
        }
        let units = Array(text.utf16)
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw PluginError(code: "INPUT_EVENT_CREATE_FAILED", message: "Could not create Unicode keyboard events", retryable: true, domain: "input")
        }
        units.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
