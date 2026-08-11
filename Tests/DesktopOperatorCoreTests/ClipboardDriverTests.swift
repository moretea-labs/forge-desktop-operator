import AppKit
import Foundation
import Testing
@testable import DesktopOperatorCore

@Test func clipboardDriverReadsAndWritesIsolatedPasteboardText() {
    let board = NSPasteboard(name: NSPasteboard.Name("forge-desktop-operator-test-\(UUID().uuidString)"))
    #expect(ClipboardDriver.readText(pasteboard: board) == nil)
    #expect(ClipboardDriver.writeText("Forge clipboard", pasteboard: board))
    #expect(ClipboardDriver.readText(pasteboard: board) == "Forge clipboard")
}
