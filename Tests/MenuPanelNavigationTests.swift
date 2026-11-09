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
        let capture = MenuPanelWindowCapture.WindowCaptureView(reference: reference)
        unrelated.contentView = capture
        precondition(reference.window === unrelated)
        unrelated.contentView = nil
        precondition(reference.window == nil)
        print("PASS: menu panel closes before dashboard opens; other windows preserved; missing capture and window lifecycle covered")
    }
}
