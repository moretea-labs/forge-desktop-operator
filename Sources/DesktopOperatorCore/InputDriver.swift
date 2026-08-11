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
        let point = CGPoint(x: x, y: y)
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw PluginError(code: "INPUT_EVENT_CREATE_FAILED", message: "Could not create mouse events", retryable: true, domain: "input")
        }
        move.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        up.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
    }

    public static func press(keys: [String]) throws {
        let normalized = keys.map { $0.lowercased() }
        guard let keyName = normalized.last(where: { !["cmd", "command", "meta", "shift", "option", "alt", "control", "ctrl"].contains($0) }),
              let keyCode = keyCodes[keyName] else {
            throw PluginError.invalidArguments("Unsupported key combination: \(keys.joined(separator: "+"))")
        }
        var flags: CGEventFlags = []
        if normalized.contains(where: { ["cmd", "command", "meta"].contains($0) }) { flags.insert(.maskCommand) }
        if normalized.contains("shift") { flags.insert(.maskShift) }
        if normalized.contains(where: { ["option", "alt"].contains($0) }) { flags.insert(.maskAlternate) }
        if normalized.contains(where: { ["control", "ctrl"].contains($0) }) { flags.insert(.maskControl) }

        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
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
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
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
