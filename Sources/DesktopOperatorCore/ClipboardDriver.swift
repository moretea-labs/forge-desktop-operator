import AppKit
import Foundation

public enum ClipboardDriver {
    public static func readText(pasteboard: NSPasteboard = .general) -> String? {
        pasteboard.string(forType: .string)
    }

    @discardableResult
    public static func writeText(_ text: String, pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
