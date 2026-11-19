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
            message: "固件限充 75%–80%；充放电由固件决定", sleepHoldActive: false, firmwareExpected: FirmwareSettings(activation:2,upper:80,lower:75), firmwareObserved: FirmwareSettings(activation:2,upper:80,lower:75), capabilities: 14)
        model.battery = battery; model.state = state
        model.target = 80; model.dischargeTarget = 50; model.dischargeKeepAwake = false
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
    @MainActor static func render<V: View>(_ content: V, size: CGSize, path: URL, scheme: ColorScheme = .light) throws {
        let root = VStack(spacing: 0) {
            content
            HStack {
                Spacer()
                Text("演示数据 · v\(appVersion)").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.horizontal, 12).padding(.vertical, 6)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, scheme)
        let view = NSHostingView(rootView: root)
        view.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
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
    static func demoUpdate() -> AppUpdate {
        let version = AppReleaseVersion("0.6.11")!
        let releaseURL = URL(string: UpdateValidation.repository + "/releases/tag/v\(version)")!
        let assetsURL = URL(string: UpdateValidation.repository + "/releases/download/v\(version)")!
        let name = "Cellmori-\(version)-arm64.pkg"
        let package = ReleaseAsset(name: name, browser_download_url: assetsURL.appendingPathComponent(name),
                                   size: 700_000)
        let checksum = ReleaseAsset(name: name + ".sha256", browser_download_url: assetsURL.appendingPathComponent(name + ".sha256"),
                                    size: 91)
        return AppUpdate(version: version, releaseURL: releaseURL, notes: "演示版本", package: package, checksum: checksum)
    }

    @MainActor static func verifyPanelLayout(size: CGSize) throws {
        let model = demoModel()
        let panel = MenuPopover(previewSize: size).environmentObject(model)
        let host = NSHostingView(rootView: panel)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 130, y: 80), size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        let originalFrame = window.frame
        let savedState = model.state
        let savedService = model.service
        let steps: [(String, () -> Void)] = [
            ("applied", {}),
            ("editing with 1% gap", { model.target = 90; model.rechargeGap = 1 }),
            ("submitting", { model.busy = true }),
            ("full", {
                model.busy = false
                model.state?.configuration.mode = .full
            }),
            ("discharge", { model.state?.configuration.mode = .discharge }),
            ("calibration", { model.state?.configuration.mode = .calibrate }),
            ("unresponsive", {
                model.state = savedState
                model.target = 80
                model.rechargeGap = 5
                model.service.condition = .stale
            }),
            ("reconnected", { model.service = savedService }),
            ("update available", { model.updates.showPreviewUpdate(demoUpdate()) })
        ]
        for (name, transition) in steps {
            transition()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            host.layoutSubtreeIfNeeded()
            guard host.fittingSize == size, window.frame == originalFrame else {
                throw CMError.message("Panel moved or resized in \(name): fitting \(host.fittingSize), frame \(window.frame)")
            }
            if name == "unresponsive" && model.limitApplied {
                throw CMError.message("Unresponsive service was shown as applied")
            }
            if (name == "applied" || name == "reconnected") && !model.limitApplied {
                throw CMError.message("Confirmed range was missing in \(name)")
            }
        }
        print("Stable panel frame \(Int(size.width)) × \(Int(size.height)): \(steps.count) states, original origin retained")
    }

    @MainActor static func verifyAppearance() throws {
        let original = NSApp.appearance
        defer { NSApp.appearance = original }
        NSApp.appearance = NSAppearance(named: .aqua)
        let model = demoModel()
        let panel = MenuPopover(previewSize: MenuPopover.standardSize).environmentObject(model)
        let dashboard = Dashboard().environmentObject(model)
        let allWindows = [NSHostingView(rootView: panel) as NSView, NSHostingView(rootView: dashboard)].map { host in
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize),
                                  styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = host
            return window
        }
        defer { allWindows.forEach { $0.close() } }

        func verify(_ name: NSAppearance.Name, step: String) throws {
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            for window in allWindows {
                guard window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == name,
                      let view = window.contentView else {
                    throw CMError.message("Unexpected effective appearance during \(step)")
                }
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    throw CMError.message("Unable to sample interface appearance during \(step)")
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let x = bitmap.pixelsWide - 24
                let y = bitmap.pixelsHigh - 52
                let brightness = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.redComponent ?? -1
                guard brightness >= 0, (brightness < 0.5) == (name == .darkAqua) else {
                    throw CMError.message("Visible colors did not switch during \(step) (sample \(brightness))")
                }
            }
        }

        try verify(.aqua, step: "initial system light")
        model.appearance = .dark
        try verify(.darkAqua, step: "forced dark")
        model.appearance = .system
        try verify(.aqua, step: "dark back to system light")
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try verify(.darkAqua, step: "system changes to dark")
        model.appearance = .light
        try verify(.aqua, step: "forced light")
        model.appearance = .system
        try verify(.darkAqua, step: "light back to system dark")
        print("Rendered dashboard and panel colors follow actual appearance changes and restore the system appearance")
    }

    @MainActor static func verifyChargeRangeDraft() throws {
        let model = demoModel()
        let saved = model.state?.configuration
        guard !model.hasChargeRangeDraft else { throw CMError.message("Saved range was shown as a draft") }
        model.target = Double(shiftedChargeUpper(Int(model.target), by: -7))
        guard model.rechargeAt == 68, model.target == 73, model.hasChargeRangeDraft else {
            throw CMError.message("Moving the range left changed the spacing or lost the draft")
        }
        model.target = Double(shiftedChargeUpper(Int(model.target), by: 12))
        guard model.rechargeAt == 80, model.target == 85,
              shiftedChargeUpper(43, by: -8) == 40, shiftedChargeUpper(97, by: 8) == 100 else {
            throw CMError.message("Moving the range right or clamping the limits failed")
        }
        guard chargeRangeMovingLower(68, anchoredAt: 90) == (68, 88),
              chargeRangeMovingLower(75, anchoredAt: 90) == (75, 90),
              chargeRangeMovingLower(20, anchoredAt: 90) == (20, 40),
              chargeRangeMovingLower(89, anchoredAt: 90) == (89, 90) else {
            throw CMError.message("Left handle did not push the range left at the maximum gap")
        }
        model.rechargeGap = 12
        model.busy = true
        model.revertChargeRangeDraft()
        guard model.target == 85, model.rechargeGap == 12 else {
            throw CMError.message("Revert changed a range during submission")
        }
        model.busy = false
        model.revertChargeRangeDraft()
        guard model.target == 80, model.rechargeAt == 75, !model.hasChargeRangeDraft,
              model.state?.configuration.target == saved?.target,
              model.state?.configuration.rechargeAt == saved?.rechargeAt else {
            throw CMError.message("Revert did not restore the stored range locally")
        }
        print("Charge range moves in both directions, clamps at the boundaries and reverts without changing the saved policy")
    }

    static func verifyMetricAlignment(in file: URL, columnCenters: [Int],
                                      labels: Range<Int>, values: Range<Int>) throws {
        guard let image = NSBitmapImageRep(data: try Data(contentsOf: file)) else {
            throw CMError.message("Could not read \(file.lastPathComponent)")
        }
        func center(in region: Range<Int>, rows: Range<Int>) -> Double? {
            let ink = region.filter { x in
                rows.contains { y in
                    guard let pixel = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return pixel.alphaComponent > 0.5 && pixel.redComponent < 0.45
                }
            }
            guard let left = ink.first, let right = ink.last else { return nil }
            return Double(left + right) / 2
        }
        for expected in columnCenters {
            let region = (expected - 49)..<(expected + 50)
            guard let label = center(in: region, rows: labels),
                  let value = center(in: region, rows: values),
                  abs(label - Double(expected)) <= 6,
                  abs(value - label) <= 5 else {
                throw CMError.message("Metric column at \(expected) is not centered in \(file.lastPathComponent)")
            }
        }
    }

    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        guard CommandLine.arguments.count == 2 else { throw CMError.message("Output directory required") }
        try verifyPanelLayout(size: MenuPopover.standardSize)
        try verifyPanelLayout(size: CGSize(width: 384, height: 280))
        try verifyAppearance()
        try verifyChargeRangeDraft()
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let pages = [(0, "charge-control"), (1, "battery-health"), (2, "background-service"),
                     (3, "software-updates"), (4, "device-support")]
        for (page, name) in pages {
            let model = demoModel()
            model.selectedPage = page
            try render(Dashboard().environmentObject(model), size: CGSize(width: 940, height: 700),
                       path: output.appendingPathComponent(name + ".png"))
            try render(Dashboard().environmentObject(model), size: CGSize(width: 760, height: 585),
                       path: output.appendingPathComponent(name + "-compact.png"))
            model.appearance = .dark
            try render(Dashboard().environmentObject(model), size: CGSize(width: 940, height: 700),
                       path: output.appendingPathComponent(name + "-dark.png"), scheme: .dark)
            if page != 0 {
                for (themeSuffix, scheme) in [("", ColorScheme.light), ("-dark", .dark)] {
                    model.appearance = scheme == .dark ? .dark : .light
                    try render(Dashboard().environmentObject(model), size: CGSize(width: 940, height: 1140),
                               path: output.appendingPathComponent(name + "-full" + themeSuffix + ".png"), scheme: scheme)
                }
            }
        }

        let install = demoModel()
        install.selectedPage = 3
        let fixture = demoUpdate()
        install.updates.showPreviewUpdate(fixture, downloaded: VerifiedUpdate(
            update: fixture, file: output.appendingPathComponent(fixture.package.name), sha256: String(repeating: "0", count: 64)))
        try render(Dashboard().environmentObject(install), size: CGSize(width: 940, height: 700),
                   path: output.appendingPathComponent("update-install-guidance.png"))
        try render(Dashboard().environmentObject(install), size: CGSize(width: 760, height: 585),
                   path: output.appendingPathComponent("update-install-guidance-compact.png"))

        let normal = demoModel()
        let draft = demoModel()
        draft.target = 90
        let submitting = demoModel()
        submitting.target = 90
        submitting.busy = true
        let discharge = demoModel()
        discharge.battery?.percent = 84
        discharge.battery?.providingPowerSource = "Battery Power"
        discharge.battery?.amperage = -600
        discharge.state?.configuration.mode = .discharge
        discharge.state?.configuration.dischargeTarget = 80
        discharge.state?.dischargeCommand = true
        discharge.state?.battery = discharge.battery
        let full = demoModel()
        full.battery?.charging = true
        full.battery?.amperage = 1200
        full.state?.configuration.mode = .full
        let calibration = demoModel()
        calibration.state?.configuration.mode = .calibrate
        calibration.state?.configuration.stage = "discharge"
        calibration.state?.message = "校准 3/4：放电至 20%"
        let stale = demoModel()
        stale.service.condition = .stale
        let update = demoModel()
        update.updates.showPreviewUpdate(demoUpdate())

        let panelStates = [("", normal), ("-editing", draft), ("-submitting", submitting),
                           ("-active", discharge), ("-full", full), ("-calibration", calibration),
                           ("-stale", stale), ("-update", update)]
        for (suffix, model) in panelStates {
            for (themeSuffix, scheme) in [("", ColorScheme.light), ("-dark", .dark)] {
                model.appearance = scheme == .dark ? .dark : .light
                try render(MenuPopover().environmentObject(model), size: CGSize(width: 384, height: 473),
                           path: output.appendingPathComponent("menu-panel" + suffix + themeSuffix + ".png"), scheme: scheme)
            }
        }
        for (suffix, model) in [("-editing", draft), ("-submitting", submitting),
                                ("-active", discharge), ("-stale", stale)] {
            model.appearance = .light
            try render(Dashboard().environmentObject(model), size: CGSize(width: 940, height: 700),
                       path: output.appendingPathComponent("charge-control" + suffix + ".png"))
        }
        discharge.appearance = .light
        try render(MenuPopover(previewSize: CGSize(width: 384, height: 280)).environmentObject(discharge),
                   size: CGSize(width: 384, height: 305), path: output.appendingPathComponent("menu-panel-short.png"))
        try verifyMetricAlignment(in: output.appendingPathComponent("menu-panel.png"),
                                  columnCenters: [72, 192, 312], labels: 87..<100, values: 102..<118)
        try verifyMetricAlignment(in: output.appendingPathComponent("charge-control.png"),
                                  columnCenters: [531, 682, 833], labels: 89..<103, values: 107..<123)
        print("Battery labels and readings are centered in each column in both windows")
    }
}
