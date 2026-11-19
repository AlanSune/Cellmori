// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

/// Keep the exact window hosting the menu panel, without retaining it or relying
/// on SwiftUI's private window class names / the application's current key window.
@MainActor final class MenuPanelWindowReference {
    weak var window: NSWindow?
}

struct InterfaceWindowCapture: NSViewRepresentable {
    var reference: MenuPanelWindowReference?
    var appearance: NSAppearance?

    func makeNSView(context: Context) -> WindowCaptureView {
        WindowCaptureView(reference: reference, appearance: appearance)
    }

    func updateNSView(_ view: WindowCaptureView, context: Context) {
        view.reference = reference
        view.preferredAppearance = appearance
        reference?.window = view.window
        view.applyAppearance()
    }

    final class WindowCaptureView: NSView {
        var reference: MenuPanelWindowReference?
        var preferredAppearance: NSAppearance?

        init(reference: MenuPanelWindowReference?, appearance: NSAppearance? = nil) {
            self.reference = reference
            preferredAppearance = appearance
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reference?.window = window
            applyAppearance()
        }

        func applyAppearance() {
            if let window, window.appearance != preferredAppearance {
                window.appearance = preferredAppearance
            }
        }
    }
}

struct RangeFocusBoundary: NSViewRepresentable {
    let onExit: (() -> Void)?

    func makeNSView(context: Context) -> BoundaryView { BoundaryView() }

    func updateNSView(_ view: BoundaryView, context: Context) {
        view.onExit = onExit
    }

    static func dismantleNSView(_ view: BoundaryView, coordinator: ()) {
        view.onExit = nil
    }

    final class BoundaryView: NSView {
        var onExit: (() -> Void)? {
            didSet { updateObservation() }
        }

        private var mouseMonitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObservation()
            updateObservation()
        }

        private func updateObservation() {
            guard let window, onExit != nil else {
                stopObservation()
                return
            }
            guard mouseMonitor == nil else { return }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                self?.dismissIfOutside(window: event.window, location: event.locationInWindow)
                return event
            }
            NotificationCenter.default.addObserver(self, selector: #selector(windowExited),
                                                   name: NSWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowExited),
                                                   name: NSWindow.willCloseNotification, object: window)
        }

        private func stopObservation() {
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
                self.mouseMonitor = nil
            }
            NotificationCenter.default.removeObserver(self)
        }

        func dismissIfOutside(window source: NSWindow?, location: NSPoint) {
            guard let window else { return }
            if source !== window || !bounds.contains(convert(location, from: nil)) {
                onExit?()
            }
        }

        @objc private func windowExited(_ notification: Notification) {
            onExit?()
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
