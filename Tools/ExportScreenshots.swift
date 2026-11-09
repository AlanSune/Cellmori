// SPDX-License-Identifier: MIT
// Render the production SwiftUI views with demo data; never open an onscreen
// window, read hardware, install a service, or write application preferences.
import AppKit
import SwiftUI

@main struct ExportScreenshots {
    @MainActor static func demoModel() -> Model {
        let model = Model(preview: true)
        let battery = Battery(percent: 80, temperature: 29.2, cycles: 88, design: 5103, nominal: 4848,
            voltage: 12.1, amperage: 0, external: true, charging: false, full: false,
            failure: 0, lidClosed: false, providingPowerSource: "AC Power")
        var config = Configuration(); config.mode = .limit; config.target = 80
        let state = ServiceState(configuration: config, battery: battery,
            message: "固件限充 75%–80%；充放电由固件决定", capabilities: 14)
        model.battery = battery; model.state = state
        model.target = 80; model.dischargeTarget = 50
        model.systemHealth = "95%"; model.machineModel = "MacBook Pro（演示）"
        model.firmwareVersion = "演示数据"
        model.service = ServiceInspection.classify(binary: true, plist: true, registered: true,
            running: true, pid: 2026, state: state, now: Date())
        model.service.state?.daemonPID = 2026
        model.updates.automaticallyCheck = true
        model.loginEnabled = false
        model.samples = (0..<97).map { i in
            let percent = i < 30 ? 57 + Double(i) * 0.75 : 80 + sin(Double(i) / 9) * 0.3
            return Sample(date: Date().addingTimeInterval(Double(i - 96) * 900), percent: min(80, percent),
                temperature: 28 + sin(Double(i) / 12) * 2, watts: i < 30 ? 16 : 0, health: 95)
        }
        return model
    }
    @MainActor static func render<V: View>(_ content: V, size: CGSize, path: URL) throws {
        let root = VStack(spacing: 0) {
            content
            HStack {
                Spacer()
                Text("演示数据 · v\(appVersion)").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.horizontal, 12).padding(.vertical, 6)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)
        let view = NSHostingView(rootView: root)
        view.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CMError.message("Cannot allocate screenshot bitmap")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CMError.message("PNG encoding failed") }
        try png.write(to: path)
        window.contentView = nil
        window.close()
        print("Rendered \(path.lastPathComponent): \(bitmap.pixelsWide) × \(bitmap.pixelsHigh)")
    }
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        guard CommandLine.arguments.count == 2 else { throw CMError.message("Output directory required") }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (page, name) in [(0, "charge-control"), (1, "battery-health"), (2, "background-service"), (3, "software-updates")] {
            let model = demoModel(); model.selectedPage = page
            try render(Dashboard().environmentObject(model), size: CGSize(width: 1000, height: page == 1 ? 1040 : page == 3 ? 1120 : 880),
                       path: output.appendingPathComponent(name + ".png"))
        }
        try render(MenuPopover().environmentObject(demoModel()), size: CGSize(width: 360, height: 415),
                   path: output.appendingPathComponent("menu-panel.png"))
    }
}
