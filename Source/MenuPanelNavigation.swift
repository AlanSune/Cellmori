// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

/// Keep the exact window hosting the menu panel, without retaining it or relying
/// on SwiftUI's private window class names / the application's current key window.
@MainActor final class MenuPanelWindowReference {
    weak var window: NSWindow?
}

struct MenuPanelWindowCapture: NSViewRepresentable {
    let reference: MenuPanelWindowReference
    func makeNSView(context: Context) -> WindowCaptureView { WindowCaptureView(reference: reference) }
    func updateNSView(_ view: WindowCaptureView, context: Context) { view.reference = reference }

    final class WindowCaptureView: NSView {
        var reference: MenuPanelWindowReference
        init(reference: MenuPanelWindowReference) {
            self.reference = reference
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reference.window = window
        }
    }
}

@MainActor enum MenuPanelNavigation {
    static func openDashboard(from panel: NSWindow?, prepare: () -> Void,
                              show: () -> Void, activate: () -> Void) {
        // close() also ends the panel's presentation lifecycle. Merely ordering it
        // out can leave the status item believing its panel is still presented.
        // Never accidentally close a dashboard that was supplied as the source.
        if let panel, panel.identifier?.rawValue != "dashboard" { panel.close() }
        prepare()
        show()
        activate()
    }
}
