// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

@MainActor final class ObservedWindow: NSWindow {
    var closeCount = 0
    var onClose: (() -> Void)?
    override func close() { closeCount += 1; onClose?(); super.close() }
}

@main struct MenuPanelNavigationTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        func makeWindow(_ name: String) -> ObservedWindow {
            let w = ObservedWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                   styleMask: [.borderless], backing: .buffered, defer: true)
            w.isReleasedWhenClosed = false
            w.identifier = NSUserInterfaceItemIdentifier(name)
            return w
        }
        let panel = makeWindow("test-menu-panel")
        let dashboard = makeWindow("dashboard")
        let unrelated = makeWindow("unrelated-window")
        var events: [String] = []
        panel.onClose = { events.append("close panel") }
        MenuPanelNavigation.openDashboard(from: panel, prepare: { events.append("prepare") },
            show: { events.append("open dashboard") }, activate: { events.append("activate") })
        precondition(events == ["close panel", "prepare", "open dashboard", "activate"])
        precondition(panel.closeCount == 1 && dashboard.closeCount == 0 && unrelated.closeCount == 0)
        var openedWithoutCapture = false
        MenuPanelNavigation.openDashboard(from: nil, prepare: {}, show: { openedWithoutCapture = true }, activate: {})
        precondition(openedWithoutCapture)
        MenuPanelNavigation.openDashboard(from: dashboard, prepare: {}, show: {}, activate: {})
        precondition(dashboard.closeCount == 0)
        let reference = MenuPanelWindowReference()
        let capture = InterfaceWindowCapture.WindowCaptureView(reference: reference)
        unrelated.contentView = capture
        precondition(reference.window === unrelated)
        unrelated.contentView = nil
        precondition(reference.window == nil)
        let editor = RangeFocusBoundary.BoundaryView(frame: NSRect(x: 10, y: 10, width: 45, height: 35))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        dashboard.contentView = content
        content.addSubview(editor)
        defer { editor.onExit = nil }
        var dismissed = 0
        editor.onExit = { dismissed += 1 }
        editor.dismissIfOutside(window: dashboard, location: NSPoint(x: 20, y: 20))
        precondition(dismissed == 0)
        editor.dismissIfOutside(window: dashboard, location: NSPoint(x: 70, y: 20))
        precondition(dismissed == 1)
        editor.dismissIfOutside(window: unrelated, location: NSPoint(x: 20, y: 20))
        precondition(dismissed == 2)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: unrelated)
        precondition(dismissed == 2)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: dashboard)
        precondition(dismissed == 3)
        editor.onExit = nil
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: dashboard)
        precondition(dismissed == 3)
        print("PASS: menu panel closes before dashboard opens; other windows preserved; range focus cleared on outside clicks and window deactivation")
    }
}
