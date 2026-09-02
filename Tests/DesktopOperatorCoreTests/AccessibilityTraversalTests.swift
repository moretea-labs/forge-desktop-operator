import ApplicationServices
import Testing
@testable import DesktopOperatorCore

@Test func applicationTraversalIncludesWindowAndMenuFallbacksWithoutDuplicates() {
    let child = AXUIElementCreateApplication(10_001)
    let focusedWindow = AXUIElementCreateApplication(10_002)
    let mainWindow = AXUIElementCreateApplication(10_003)
    let menuBar = AXUIElementCreateApplication(10_004)
    let focusedElement = AXUIElementCreateApplication(10_005)

    let merged = AccessibilityDriver.mergeApplicationTraversalElements(
        children: [child],
        windows: [focusedWindow, child],
        focusedWindow: focusedWindow,
        mainWindow: mainWindow,
        menuBar: menuBar,
        focusedElement: focusedElement
    )

    #expect(merged.count == 5)
    #expect(CFEqual(merged[0], child))
    #expect(CFEqual(merged[1], focusedWindow))
    #expect(CFEqual(merged[2], mainWindow))
    #expect(CFEqual(merged[3], menuBar))
    #expect(CFEqual(merged[4], focusedElement))
}

@Test func applicationTraversalCanRecoverWhenAXChildrenIsEmpty() {
    let onlyWindow = AXUIElementCreateApplication(20_001)
    let merged = AccessibilityDriver.mergeApplicationTraversalElements(
        children: [],
        windows: [onlyWindow],
        focusedWindow: nil,
        mainWindow: nil,
        menuBar: nil,
        focusedElement: nil
    )

    #expect(merged.count == 1)
    #expect(CFEqual(merged[0], onlyWindow))
}
