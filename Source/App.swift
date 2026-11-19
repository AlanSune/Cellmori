// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import Charts
import ServiceManagement
import UniformTypeIdentifiers
import IOKit.ps

struct Sample: Codable, Identifiable {
    var date: Date
    var percent: Double
    var temperature: Double
    var watts: Double
    var health: Double?
    var id: Date { date }
}

enum AppAppearance: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var nativeAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor final class Model: ObservableObject {
    @Published var battery: Battery?
    @Published var state: ServiceState?
    @Published var target: Double = 80
    @Published var rechargeGap = defaultRechargeGap
    var rechargeAt: Int { Int(target) - rechargeGap }
    @Published var dischargeTarget: Double = 50
    @Published var dischargeKeepAwake = UserDefaults.standard.bool(forKey: "dischargeKeepAwake") {
        didSet { if !isPreview { UserDefaults.standard.set(dischargeKeepAwake, forKey: "dischargeKeepAwake") } }
    }
    @Published var temperatureLimit: Double = 40
    @Published var error: String? { didSet { if let error { enqueueError(error) } } }
    @Published var notice: String?
    @Published var busy = false
    @Published var samples: [Sample] = []
    @Published var probeText = "尚未检测"
    @Published var systemHealth = "读取中…"
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var service = ServiceInspection()
    @Published var checkingService = false
    @Published var selectedPage = 0
    @Published var temporaryOperationsRequest: UUID?
    @Published var firmwareVersion = "读取中…"
    @Published var machineModel = "读取中…"
    @Published var lastClosedDockPolicy = UserDefaults.standard.string(forKey: "lastClosedDockPolicy")
    @Published var showDockWhenPanelClosed = UserDefaults.standard.object(forKey: "showDockWhenPanelClosed") as? Bool ?? true {
        didSet {
            guard !isPreview else { return }
            UserDefaults.standard.set(showDockWhenPanelClosed, forKey: "showDockWhenPanelClosed")
            updateDockVisibility()
        }
    }
    @Published var appearance: AppAppearance = .system {
        didSet {
            guard !isPreview else { return }
            UserDefaults.standard.set(appearance.rawValue, forKey: "appAppearance")
        }
    }
    @Published private var systemAppearance: NSAppearance
    private var appearanceObserver: NSKeyValueObservation?
    var interfaceAppearance: NSAppearance { appearance.nativeAppearance ?? systemAppearance }
    var interfaceColorScheme: ColorScheme {
        interfaceAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    private var windowObservers: [NSObjectProtocol] = []
    private var lastBatteryError: String?
    private var lastBackendError: String?
    private var errorQueue: [String] = []
    private var showingError = false
    private var lastAlert: (String, Date)?
    private var timer: Timer?
    private var powerSourceNotification: CFRunLoopSource?
    private var powerObservers: [NSObjectProtocol] = []
    private var wakeObservers: [NSObjectProtocol] = []
    private var transitionRefresh: Task<Void, Never>?
    private static let powerChanged = Notification.Name("CellmoriPowerSourceChanged")
    private var loadedSettings = false
    private var historyErrorReported = false
    private let historyDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cellmori")
    var installed: Bool { isPreview || FileManager.default.isExecutableFile(atPath: helperPath) }
    var live: Bool { state.map { Date().timeIntervalSince($0.updated) < 65 } ?? false }
    var firmwareBackend: Bool { (state?.capabilities ?? 0) & 4 != 0 }
    var chargeAvailable: Bool {
        installed && live && service.healthy && state?.helperVersion == expectedHelperVersion &&
            state?.configuration.mode != .retiredAdapterLimit && (state?.capabilities ?? 0) & 5 != 0
    }
    var fullAvailable: Bool { chargeAvailable }
    var dischargeAvailable: Bool { fullAvailable && (state?.capabilities ?? 0) & 2 != 0 }
    var temporaryFlow: Bool { state.map { [.full, .discharge, .calibrate].contains($0.configuration.mode) } ?? false }
    var limitApplied: Bool {
        chargeAvailable && state?.error == nil && limitSettingsApplied(
            state?.configuration, target: Int(target), temperature: temperatureLimit, rechargeGap: rechargeGap
        )
    }
    var hasChargeRangeDraft: Bool {
        guard let saved = state?.configuration else { return false }
        return Int(target) != saved.target || rechargeGap != saved.effectiveRechargeGap
    }

    func revertChargeRangeDraft() {
        guard !busy, !temporaryFlow, let saved = state?.configuration else { return }
        target = Double(saved.target)
        rechargeGap = saved.effectiveRechargeGap
    }

    var activeFlowTitle: String { state?.configuration.mode.title ?? "临时流程" }
    var activeFlowSymbol: String {
        switch state?.configuration.mode {
        case .discharge: return "battery.25percent"
        case .calibrate: return "arrow.triangle.2.circlepath"
        default: return "battery.100percent"
        }
    }
    var canStopTemporaryFlow: Bool { service.healthy && live && state?.helperVersion == expectedHelperVersion && !busy }
    var stopFlowTitle: String {
        switch state?.configuration.mode {
        case .discharge: return "停止放电"
        case .full: return "取消充满一次"
        default: return "停止校准"
        }
    }
    var status: String {
        guard installed else { return "只读监测 · 尚未安装后台服务" }
        guard live else { return "后台状态过期，请检查服务" }
        if state?.error != nil { return "策略待确认 · 后台正在重试" }
        var flowBattery = battery
        // The helper uses independent physical AC detection, unlike the raw flag
        // which can disappear when this app deliberately cuts adapter power.
        if let physical = state?.battery?.external { flowBattery?.external = physical }
        if let c = state?.configuration, let flow = temporaryFlowStatus(c, battery: flowBattery, sleepHoldActive: state?.sleepHoldActive == true) { return flow }
        return state?.message ?? "等待后台服务"
    }
    var percentageText: String { battery.map { "\(Int($0.percent.rounded()))%" } ?? "—" }
    var powerDisplay: PowerDisplayState { PowerDisplayState.resolve(battery) }
    let updates: AppUpdater
    private let isPreview: Bool
    init(preview: Bool = false) {
        isPreview = preview
        updates = AppUpdater(preview: preview)
        let application = NSApplication.shared
        systemAppearance = application.effectiveAppearance
        appearanceObserver = application.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in
                self?.systemAppearance = NSApplication.shared.effectiveAppearance
            }
        }
        if preview { return }

        if let stored = UserDefaults.standard.string(forKey: "appAppearance"),
           let saved = AppAppearance(rawValue: stored) {
            appearance = saved
        }
        updates.onError = { [weak self] message in self?.error = message }
        updates.checkAutomaticallyIfDue()
        samples = (try? decode([Sample].self, path: historyDirectory.appendingPathComponent("history.json").path)) ?? []
        refresh(); checkService()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(); self?.checkService() }
        }
        // Read live IOPowerSources as soon as macOS publishes a change, rather than
        // waiting for the periodic history/service poll.
        powerObservers.append(NotificationCenter.default.addObserver(forName: Self.powerChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            NotificationCenter.default.post(name: Notification.Name("CellmoriPowerSourceChanged"), object: nil)
        }, nil)?.takeRetainedValue() {
            powerSourceNotification = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            wakeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshAfterTransition() }
            })
        }
        readSystemHealth()
        readDeviceSummary()
        for name in [NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    guard let self, let window = notification.object as? NSWindow, window.identifier?.rawValue == "dashboard" else { return }
                    if notification.name == NSWindow.willCloseNotification {
                        NSApp.setActivationPolicy(self.showDockWhenPanelClosed ? .regular : .accessory)
                        self.lastClosedDockPolicy = NSApp.activationPolicy() == .accessory ? "hidden" : "visible"
                        UserDefaults.standard.set(self.lastClosedDockPolicy, forKey: "lastClosedDockPolicy")
                    } else { self.prepareToOpenPanel() }
                }
            })
        }
    }
    private func refreshAfterTransition() {
        transitionRefresh?.cancel()
        refresh()
        checkService()
        // Briefly observe real hardware at 4 Hz after a command or wake. Keep the
        // normal 10-second timer unchanged, and cancel any previous burst.
        transitionRefresh = Task { @MainActor [weak self] in
            for _ in 0..<60 {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }
    func prepareToOpenPanel() { if !isPreview { NSApp.setActivationPolicy(.regular) } }
    private func updateDockVisibility() {
        let panelOpen = NSApp.windows.contains { $0.identifier?.rawValue == "dashboard" && ($0.isVisible || $0.isMiniaturized) }
        NSApp.setActivationPolicy(panelOpen || showDockWhenPanelClosed ? .regular : .accessory)
    }
    func refresh() {
        do {
            let native = try Battery.read()
            var current=0.0, voltage=0.0
            battery = cm_battery_current(&current,&voltage)==0
                ? applyingLiveCurrent(native,milliamps:current,volts:voltage) : native
            lastBatteryError = nil
        }
        catch {
            battery = nil
            if lastBatteryError != error.localizedDescription { self.error = error.localizedDescription; lastBatteryError = error.localizedDescription }
        }
        state = try? decode(ServiceState.self, path: statePath)
        if live, let issue = state?.error {
            if lastBackendError != issue { lastBackendError = issue; error = issue }
        } else if state?.error == nil { lastBackendError = nil }
        if !loadedSettings, let c = state?.configuration {
            target = Double(c.target); rechargeGap = c.effectiveRechargeGap; dischargeTarget = Double(c.dischargeTarget); temperatureLimit = c.temperatureLimit
            if let keepAwake = c.dischargeKeepAwake, temporaryFlow || UserDefaults.standard.object(forKey:"dischargeKeepAwake") == nil {
                dischargeKeepAwake = keepAwake
            }
            loadedSettings = true
        }
        if let b = battery, Date().timeIntervalSince(samples.last?.date ?? .distantPast) >= 60 {
            samples.append(Sample(date: Date(), percent: b.percent, temperature: b.temperature, watts: b.watts, health: b.health))
            samples = Array(samples.filter { $0.date > Date().addingTimeInterval(-7*86400) }.suffix(10080))
            do {
                try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
                try encode(samples, path: historyDirectory.appendingPathComponent("history.json").path)
            } catch {
                if !historyErrorReported { self.error = "历史记录保存失败：" + error.localizedDescription; historyErrorReported = true }
            }
        }
    }
    private func enqueueError(_ raw: String) {
        var message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = message.range(of: "execution error: ") { message = String(message[range.upperBound...]) }
        message = message.replacingOccurrences(of: #"\s*\(-?\d+\)\s*$"#, with: "", options: .regularExpression)
        if let last = lastAlert, last.0 == message, Date().timeIntervalSince(last.1) < 5 { return }
        guard !errorQueue.contains(message) else { return }
        lastAlert = (message, Date()); errorQueue.append(message)
        Task { @MainActor in self.showNextError() }
    }
    private func showNextError() {
        guard !showingError, !errorQueue.isEmpty else { return }
        showingError = true
        let message = errorQueue.removeFirst()
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "提示")
        let hardwareIssue = ["CHIE", "SMC", "write/verification", "固件"].contains { message.localizedCaseInsensitiveContains($0) }
        alert.messageText = hardwareIssue ? "充电控制未确认" : "操作未完成"
        alert.informativeText = hardwareIssue
            ? "后台未能确认硬件已接受设置。请查看当前供电状态，并在“后台服务”中检查服务；暂时避免反复切换策略。\n\n详细信息：\n" + message
            : message
        alert.addButton(withTitle: "知道了")
        alert.addButton(withTitle: "复制详情")
        alert.window.appearance = interfaceAppearance
        NSApp.activate(ignoringOtherApps: true)
        let complete: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertSecondButtonReturn { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message, forType: .string) }
            self.showingError = false
            Task { @MainActor in self.showNextError() }
        }
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "dashboard" && $0.isVisible && $0.attachedSheet == nil }) {
            alert.beginSheetModal(for: window, completionHandler: complete)
        } else { complete(alert.runModal()) }
    }
    func showErrorDetails(_ message: String) { lastAlert = nil; enqueueError(message) }
    func checkService(report: Bool = false) {
        guard !checkingService else { return }
        checkingService = true
        Task {
            service = await Task.detached { ServiceInspection.read() }.value
            checkingService = false
            if report {
                if service.healthy { notice = "检查通过：\(serviceIdentifier) 正在运行，PID \(service.pid.map(String.init) ?? "—")。" }
                else { error = service.detail }
            }
        }
    }
    private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    func admin(_ arguments: [String], install: Bool = false, uninstall: Bool = false) {
        guard !busy else { return }
        guard let resources = Bundle.main.resourcePath else { error = "应用资源缺失"; return }
        let command: String
        if install || uninstall {
            command = "/bin/bash " + shellQuote(resources + (uninstall ? "/uninstall.sh" : "/install.sh"))
        } else {
            command = ([helperPath] + arguments).map(shellQuote).joined(separator: " ")
        }
        let scriptLiteral = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(scriptLiteral)\" with administrator privileges"
        busy = true; error = nil; notice = nil
        Task {
            let result: (Int32, String)
            if !install && !uninstall {
                if state?.helperVersion != expectedHelperVersion {
                    result = (1, "请先更新后台至 v\(expectedHelperVersion)，日常操作将通过安全通信执行，不再反复请求密码。")
                } else { result = await ControlClient.request(arguments) }
            } else {
            result = await Task.detached(priority: .userInitiated) { () -> (Int32, String) in
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
                } catch { return (1, error.localizedDescription) }
            }.value
            }
            if result.0 != 0 {
                if result.1.contains("(-128)") { notice = "已取消授权，未提交新的策略。" }
                else { error = result.1.isEmpty ? "操作失败" : result.1 }
            } else if install {
                // Installation succeeds only after the new running daemon responds.
                notice = "正在验证后台进程与首次响应…"
                var verified = false
                for _ in 0..<8 {
                    service = await Task.detached { ServiceInspection.read() }.value
                    if service.condition == .running && service.state?.daemonPID == service.pid { verified = true; break }
                    try? await Task.sleep(for: .seconds(1))
                }
                if verified { notice = "安装成功：\(serviceIdentifier) · PID \(service.pid.map(String.init) ?? "—") · v\(expectedHelperVersion)" }
                else { error = "安装命令已完成，但尚未确认新版后台正常响应。" + service.detail + "请在“后台服务”中重新检查或修复。" }
            } else {
                notice = uninstall ? "后台服务已移除，原供电策略已恢复。" : ["firmware-test", "ping"].contains(arguments.first ?? "") ? result.1 : arguments.first == "reset" ? "已归还系统管理，恢复接管前设置。" : "策略已提交，请观察实际充电状态。"
            }
            if result.0 == 0 && arguments.first == "configure" { notice = nil }
            busy = false
            if result.0 == 0 { refreshAfterTransition() }
            else { refresh(); checkService() }
        }
    }
    func apply(_ mode: Mode) {
        guard service.healthy else { error = "后台服务尚未确认正常运行，请在后台服务页检查或修复后重试。"; selectedPage = 2; return }
        guard state?.helperVersion == expectedHelperVersion else {
            error = "请先更新后台服务，再应用新版控制策略。"; selectedPage = 2; return
        }
        guard !temporaryFlow else { error = "请先停止当前临时流程，再开始新的操作。"; return }
        // Starting a temporary flow must preserve the applied daily limit, not an unsaved draft.
        let saved = state?.configuration
        let dailyTarget = [.full, .discharge, .calibrate].contains(mode) ? saved?.target ?? Int(target) : Int(target)
        let thermal = [.full, .discharge, .calibrate].contains(mode) ? saved?.temperatureLimit ?? temperatureLimit : temperatureLimit
        let gap = mode == .limit ? rechargeGap : saved?.effectiveRechargeGap ?? rechargeGap
        admin(["configure", mode.rawValue, String(dailyTarget), String(Int(thermal)), String(Int(dischargeTarget)), dischargeKeepAwake ? "1" : "0", String(gap)])
    }
    func stopTemporaryFlow() {
        guard temporaryFlow, canStopTemporaryFlow, let c = state?.configuration else { return }
        admin(["configure", Mode.limit.rawValue, String(c.target), String(Int(c.temperatureLimit)), String(c.dischargeTarget), c.dischargeKeepAwake == true ? "1" : "0", String(c.effectiveRechargeGap)])
    }
    func readDeviceSummary() {
        Task {
            let info = await Task.detached { () -> [String:String] in
                let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/sbin/system_profiler");process.arguments=["SPHardwareDataType","-json"]
                let pipe=Pipe();process.standardOutput=pipe;process.standardError=FileHandle.nullDevice
                do {
                    try process.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
                    let root=try JSONSerialization.jsonObject(with:data) as? [String:Any]
                    let hardware=(root?["SPHardwareDataType"] as? [[String:Any]])?.first
                    return ["firmware":hardware?["boot_rom_version"] as? String ?? "未知", "model":hardware?["machine_model"] as? String ?? "未知"]
                } catch { return [:] }
            }.value
            firmwareVersion=info["firmware"] ?? "未知";machineModel=info["model"] ?? "未知"
        }
    }
    func openBatterySettings() {
        guard let url=URL(string:"x-apple.systempreferences:com.apple.Battery-Settings.extension"),NSWorkspace.shared.open(url) else {
            error="无法打开电池设置，请手动前往：系统设置 → 电池 → 充电。";return
        }
    }
    func exportCompatibility() {
        probe()
        let panel=NSSavePanel();panel.nameFieldStringValue="Cellmori-compatibility.json";panel.allowedContentTypes=[.json]
        panel.appearance = interfaceAppearance
        guard panel.runModal() == .OK,let url=panel.url else {return}
        let report:[String:String] = ["time":ISO8601DateFormatter().string(from:Date()),"appVersion":appVersion,"helperVersion":service.state?.helperVersion ?? "unknown", "serviceName":serviceIdentifier,"os":ProcessInfo.processInfo.operatingSystemVersionString,"architecture":"arm64","model":machineModel,"firmware":firmwareVersion,"readableCapabilities":String(state?.capabilities ?? 0),"activeMode":state?.configuration.mode.rawValue ?? "unknown","probe":probeText,"macOS26Validation":"Not hardware-tested; runtime probing and explicit adapter fallback only"]
        do { let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];try encoder.encode(report).write(to:url,options:.atomic) }
        catch {self.error=error.localizedDescription}
    }
    func confirm(_ mode: Mode) {
        let alert = NSAlert()
        let dailyLimit = state?.configuration.target ?? Int(target)
        alert.messageText = mode == .calibrate ? "开始电量校准？" : "开始放电至 \(Int(dischargeTarget))%？"
        alert.informativeText = mode == .calibrate
          ? "电脑会依次充满电、保持满电 30 分钟、放电至 20%，然后再次充满。整个流程可能需要数小时。\n\n请接通电源并保持开盖。你可以随时点击“停止校准”，恢复已保存的 \(dailyLimit)% 日常上限。校准用于观察电量计量表现，不能修复电池老化。"
          : "即使插着电源，电脑也会暂时使用电池，让电量降至 \(Int(dischargeTarget))%。达到目标后，恢复适配器供电，并继续执行已保存的 \(dailyLimit)% 日常上限。\n\n放电期间请保持开盖。睡眠或合盖会暂停主动放电，唤醒并开盖后继续。你可以随时点击“停止放电”。"
        if dischargeKeepAwake {
            alert.informativeText = alert.informativeText.replacingOccurrences(of:"请接通电源并保持开盖。", with:"请接通电源。")
                .replacingOccurrences(of:"放电期间请保持开盖。睡眠或合盖会暂停主动放电，唤醒并开盖后继续。", with:"")
            alert.informativeText += "\n\n已开启放电期间保持唤醒：主动放电阶段会暂时禁止系统睡眠，合盖后电脑仍在运行。达到目标、暂停、停止或断开电源后恢复原睡眠设置。校准的其他阶段仍按系统睡眠设置运行。"
        }
        alert.addButton(withTitle: mode == .calibrate ? "开始校准" : "开始放电")
        alert.addButton(withTitle: "取消")
        alert.window.appearance = interfaceAppearance
        if alert.runModal() == .alertFirstButtonReturn { apply(mode) }
    }
    func probe() {
        var buffer = [CChar](repeating: 0, count: 1024)
        let result = cm_probe(&buffer, Int32(buffer.count))
        probeText = String(cString: buffer) + (result == 0 ? "接口可读；写入能力需管理员授权后验证。" : "普通权限读取受限或接口不支持；安装后可进行管理员检测。")
    }
    func readSystemHealth() {
        Task {
            let text = await Task.detached { () -> String in
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
                p.arguments = ["SPPowerDataType", "-json"]
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
                do {
                    try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                    let root = try JSONSerialization.jsonObject(with: data)
                    func search(_ value: Any) -> String? {
                        if let d = value as? [String: Any] {
                            if let v = d["sppower_battery_health_maximum_capacity"] { return String(describing: v) }
                            for v in d.values { if let found = search(v) { return found } }
                        }
                        if let a = value as? [Any] { for v in a { if let found = search(v) { return found } } }
                        return nil
                    }
                    return search(root) ?? "系统未提供"
                } catch { return "暂不可用" }
            }.value
            systemHealth = text
        }
    }
    func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Cellmori-history.csv"; panel.allowedContentTypes = [.commaSeparatedText]
        panel.appearance = interfaceAppearance
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let formatter = ISO8601DateFormatter()
        let rows = samples.map { "\(formatter.string(from: $0.date)),\($0.percent),\($0.temperature),\($0.watts),\($0.health.map(String.init(describing:)) ?? "")" }
        do { try ("timestamp,battery_percent,temperature_c,battery_watts,estimated_health_percent\n" + rows.joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = error.localizedDescription }
    }
    func toggleLogin() {
        do {
            if loginEnabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
            loginEnabled = SMAppService.mainApp.status == .enabled
        } catch { self.error = error.localizedDescription }
    }
    func uninstall() {
        let alert = NSAlert(); alert.messageText = "移除后台服务？"
        alert.informativeText = "先恢复正常充电，再移除系统后台服务。应用和个人历史记录会保留。"
        alert.addButton(withTitle: "移除"); alert.addButton(withTitle: "取消")
        alert.window.appearance = interfaceAppearance
        if alert.runModal() == .alertFirstButtonReturn { admin([], uninstall: true) }
    }
}

enum CellmoriDesign {
    static let surface = color(0xf8f9fc, 0x1b202a)
    static let panel = color(0xffffff, 0x232935)
    static let rail = color(0xedf0f6, 0x202631)
    static let ink = color(0x172031, 0xedf2fb)
    static let quiet = color(0x546077, 0xacb7cd)
    static let line = color(0xdde3ed, 0x3b4559)
    static let accent = color(0x1757b7, 0x91bbff)
    static let onAccent = color(0xffffff, 0x142035)
    static let accentWash = color(0xeaf2ff, 0x273e61)
    static let good = color(0x226841, 0x92d5a7)
    static let warning = color(0x8c4b0f, 0xffc98e)

    private static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

let cellmoriAccent = Color(nsColor: .controlAccentColor)

extension PowerDisplayState {
    var interfaceColor: Color {
        switch self {
        case .charging: return .green
        case .external: return .secondary
        case .battery: return .blue
        case .unavailable: return .secondary
        }
    }
}

// Keep integer control values without the dense tick marks of a stepped slider.
func wholeNumber(_ value: Binding<Double>) -> Binding<Double> {
    Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.rounded() })
}

struct ChargeRangeEditor: View {
    @EnvironmentObject var model: Model
    @Environment(\.isEnabled) private var enabled

    var compact = false

    private enum Endpoint: Hashable { case lower, upper }
    private struct DragStart {
        let endpoint: Endpoint?
        let lower: Int
        let upper: Int
    }
    @FocusState private var focused: Endpoint?
    @State private var dragStart: DragStart?

    private let scale = 20...100
    private var inset: CGFloat { compact ? 7 : 11 }
    private var thumbSize: CGFloat { compact ? 13 : 17 }
    private var upper: Int { Int(model.target) }
    private var lower: Int { model.rechargeAt }

    var body: some View {
        VStack(spacing: compact ? 0 : 6) {
            HStack {
                endpointLabel(.lower, "恢复充电", percent: lower, alignment: .leading)
                Color.clear.frame(minWidth: 12, maxWidth: .infinity).frame(height: 30)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: clearSelection)
                    .accessibilityHidden(true)
                endpointLabel(.upper, "充电上限", percent: upper, alignment: .trailing)
            }
            .accessibilityHidden(true)
            GeometryReader { geometry in
                let width = max(1, geometry.size.width - 2 * inset)
                let left = position(lower, width: width)
                let right = position(upper, width: width)
                ZStack(alignment: .leading) {
                    Capsule().fill(CellmoriDesign.line)
                        .frame(width: width, height: 5).offset(x: inset)
                    Capsule().fill(CellmoriDesign.accent)
                        .frame(width: max(1, right - left), height: 5).offset(x: left)
                    thumb(.lower, x: left)
                    thumb(.upper, x: right)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .opacity(compact && !enabled ? 0.55 : 1)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { trackDrag($0, width: width, left: left, right: right) }
                    .onEnded { _ in dragStart = nil })
                .help("拖动蓝色区段移动整个范围，拖动手柄调整单个端点")
            }
            .frame(height: compact ? 23 : 26)
            .accessibilityRepresentation {
                VStack {
                    Slider(value: Binding(get: { Double(lower) }, set: { set(.lower, to: Int($0.rounded())) }),
                           in: Double(rechargeThresholdRange(upper: upper).lowerBound)...Double(upper - 1), step: 1)
                        .accessibilityLabel("恢复充电")
                        .accessibilityValue("\(lower)%")
                    Slider(value: Binding(get: { Double(upper) }, set: { set(.upper, to: Int($0.rounded())) }),
                           in: 40...100, step: 1)
                        .accessibilityLabel("充电上限")
                        .accessibilityValue("\(upper)%")
                }
            }
        }
        .disabled(model.busy || model.temporaryFlow)
        .background(RangeFocusBoundary(onExit: focused == nil ? nil : clearSelection))
        .onDisappear(perform: clearSelection)
        .onChange(of: enabled && !model.busy && !model.temporaryFlow) { _, canEdit in
            if !canEdit { clearSelection() }
        }
    }

    private func clearSelection() {
        focused = nil
        dragStart = nil
    }

    private func endpointLabel(_ endpoint: Endpoint, _ title: String, percent: Int,
                               alignment: HorizontalAlignment) -> some View {
        Button {
            focused = endpoint
        } label: {
            VStack(alignment: alignment, spacing: compact ? 0 : 3) {
                Text(title).font(.system(size: 12)).foregroundStyle(CellmoriDesign.quiet)
                Text("\(percent)%").font(.system(size: 22, weight: .semibold)).monospacedDigit()
            }
            .padding(.horizontal, compact ? 0 : 7).padding(.vertical, compact ? 0 : 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focused, equals: endpoint)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow], phases: [.down, .repeat]) { press in
            let amount = press.key == .leftArrow ? -1 : 1
            if press.modifiers.contains(.option) {
                guard enabled, !model.busy, !model.temporaryFlow else { return .ignored }
                model.target = Double(shiftedChargeUpper(upper, by: amount))
                return .handled
            }
            return adjust(endpoint, by: amount)
        }
        .help("方向键调整\(title) · Option + 左右方向键移动整个范围")
    }

    private func trackDrag(_ change: DragGesture.Value, width: CGFloat, left: CGFloat, right: CGFloat) {
        guard enabled, !model.busy, !model.temporaryFlow else { return }
        if dragStart == nil {
            let start = change.startLocation.x
            let thumbRadius = thumbSize / 2
            let nearest: Endpoint = abs(start - left) <= abs(start - right) ? .lower : .upper
            let overlaps = right - left < thumbSize && min(abs(start - left), abs(start - right)) <= 12
            let endpoint = start > left + thumbRadius && start < right - thumbRadius
                ? nil : (overlaps ? (focused ?? nearest) : nearest)
            dragStart = DragStart(endpoint: endpoint, lower: lower, upper: upper)
            focused = endpoint
        }
        guard let dragStart else { return }
        let span = Double(scale.upperBound - scale.lowerBound)
        if let endpoint = dragStart.endpoint {
            let fraction = min(1, max(0, (change.location.x - inset) / width))
            set(endpoint, to: scale.lowerBound + Int((fraction * span).rounded()))
        } else {
            let amount = Int((change.translation.width / width * span).rounded())
            model.target = Double(shiftedChargeUpper(dragStart.upper, by: amount))
        }
    }

    private func position(_ percent: Int, width: CGFloat) -> CGFloat {
        inset + width * Double(percent - scale.lowerBound) / Double(scale.upperBound - scale.lowerBound)
    }

    private func thumb(_ endpoint: Endpoint, x: CGFloat) -> some View {
        Circle().fill(CellmoriDesign.panel)
            .overlay(Circle().strokeBorder(CellmoriDesign.accent, lineWidth: focused == endpoint ? 3 : 2))
            .frame(width: thumbSize, height: thumbSize)
            .offset(x: x - thumbSize / 2)
            .zIndex(focused == endpoint ? 1 : 0)
    }

    private func adjust(_ endpoint: Endpoint, by amount: Int) -> KeyPress.Result {
        set(endpoint, to: (endpoint == .lower ? lower : upper) + amount)
        return .handled
    }

    private func set(_ endpoint: Endpoint, to percent: Int) {
        guard enabled, !model.busy, !model.temporaryFlow else { return }
        let range: (lower: Int, upper: Int)
        if endpoint == .lower {
            range = chargeRangeMovingLower(percent, anchoredAt: dragStart?.upper ?? upper)
        } else {
            let newUpper = shiftedChargeUpper(percent, by: 0)
            range = (rechargeThreshold(dragStart?.lower ?? lower, upper: newUpper), newUpper)
        }
        model.target = Double(range.upper)
        model.rechargeGap = range.upper - range.lower
    }
}

private struct BatteryMetrics: View {
    @EnvironmentObject private var model: Model
    var rowSpacing: CGFloat = 3

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            metric("温度", model.battery.map { String(format: "%.1f °C", $0.temperature) } ?? "—")
            metric("电池功率", model.battery.map { String(format: "%.1f W", $0.watts) } ?? "—")
            metric("健康度", model.systemHealth)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(spacing: rowSpacing) {
            Text(title).font(.system(size: 12)).foregroundStyle(CellmoriDesign.quiet)
            Text(value).font(.system(size: 14, weight: .semibold)).monospacedDigit()
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct FlowSummary: View {
    @EnvironmentObject private var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.status).font(.callout)
                .lineLimit(2).help(model.status)
            if let config = model.state?.configuration, model.live, model.service.healthy {
                Text("结束后恢复 \(config.rechargeAt)%–\(config.target)%" +
                    (model.state?.sleepHoldActive == true ? " · 保持唤醒中" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct Dashboard: View {
    @EnvironmentObject var model: Model
    @State private var showFiles = false
    @State private var showDiagnostics = false
    private let titles = ["充电控制", "健康与趋势", "后台服务", "偏好设置", "设备支持"]
    private let symbols = ["battery.75percent", "heart.text.square", "gearshape.2", "slider.horizontal.3", "checkmark.shield"]
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Cellmori")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CellmoriDesign.ink)
                    .padding(.horizontal, 19).padding(.vertical, 16)
                List(selection: $model.selectedPage) {
                    Section("电池") {
                        ForEach(0..<2, id: \.self) { index in sidebarItem(index) }
                    }
                    Section("应用") {
                        ForEach(2..<titles.count, id: \.self) { index in sidebarItem(index) }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                Button { model.selectedPage = 2 } label: {
                    HStack(spacing: 6) {
                        Circle().fill(serviceColor).frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(serviceCondition == .running ? "运行中" : serviceCondition.title)
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(serviceColor)
                }
                .buttonStyle(.plain)
                .help("\(serviceIdentifier) · \(serviceCondition.title)")
                .padding(19)
            }
            .background(CellmoriDesign.rail)
            .navigationSplitViewColumnWidth(min: 176, ideal: 192, max: 220)
        } detail: {
            GeometryReader { layout in
                VStack(alignment: .leading, spacing: 0) {
                    Text(titles[model.selectedPage])
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(CellmoriDesign.ink)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 15)
                    ScrollViewReader { proxy in
                        ScrollView {
                            Group {
                                switch model.selectedPage {
                                case 0: controls(detailWidth: layout.size.width)
                                case 1: health
                                case 2: servicePage
                                case 3: settings
                                default: compatibility
                                }
                            }
                            .frame(maxWidth: 1060)
                            .padding(.horizontal, 22).padding(.bottom, 22)
                            .frame(maxWidth: .infinity)
                        }
                        .id(model.selectedPage)
                        .onChange(of: model.temporaryOperationsRequest, initial: true) { _, request in
                            guard let request else { return }
                            Task { @MainActor in
                                await Task.yield()
                                guard model.temporaryOperationsRequest == request else { return }
                                if model.selectedPage == 0 { proxy.scrollTo("temporary-operations", anchor: .top) }
                                model.temporaryOperationsRequest = nil
                            }
                        }
                    }
                    if model.selectedPage == 0 { systemManagement }
                    if model.busy || model.notice != nil { operationNotice }
                }
                .foregroundStyle(CellmoriDesign.ink)
            }
            .toolbarBackground(CellmoriDesign.surface, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
            .toolbarColorScheme(model.interfaceColorScheme, for: .windowToolbar)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, idealWidth: 940, minHeight: 560, idealHeight: 700)
        .background(CellmoriDesign.surface)
        .tint(CellmoriDesign.accent)
        .preferredColorScheme(model.interfaceColorScheme)
        .background(InterfaceWindowCapture(appearance: model.interfaceAppearance).frame(width: 0, height: 0))
        .onAppear { model.prepareToOpenPanel() }
    }
    private var serviceCondition: ServiceCondition {
        model.service.healthy && !model.live ? .stale : model.service.condition
    }

    private var serviceColor: Color {
        switch serviceCondition {
        case .running, .updateAvailable: return CellmoriDesign.good
        case .checking, .starting: return CellmoriDesign.quiet
        default: return CellmoriDesign.warning
        }
    }

    private func sidebarItem(_ index: Int) -> some View {
        Label(titles[index], systemImage: symbols[index])
            .font(.system(size: 13, weight: model.selectedPage == index ? .semibold : .regular))
            .padding(.vertical, 3)
            .tag(index)
    }

    private var operationNotice: some View {
        HStack(spacing: 8) {
            if model.busy { ProgressView().controlSize(.small) }
            else { Image(systemName: "checkmark.circle").foregroundStyle(.green) }
            Text(model.busy ? "正在提交操作…" : (model.notice ?? ""))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            Spacer(minLength: 0)
            if !model.busy {
                Button { model.notice = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("关闭提示").help("关闭提示")
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 9)
        .background(.bar)
    }

    private func controls(detailWidth: CGFloat) -> some View {
        let wide = detailWidth >= 720
        let contentWidth = min(1060, detailWidth - 44)
        let actionsWidth = (contentWidth - 12) / 2.35
        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                          : AnyLayout(VStackLayout(spacing: 15))
        return VStack(alignment: .leading, spacing: 15) {
            batterySummary(width: contentWidth)
            layout {
                dailyCharge
                temporaryOperations
                    .frame(width: wide ? actionsWidth : nil)
                    .id("temporary-operations")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var systemManagement: some View {
        Button { model.admin(["reset"]) } label: {
            Text("交还系统管理")
                .font(.caption)
                .foregroundStyle(model.installed && !model.busy ? CellmoriDesign.accent : CellmoriDesign.quiet)
        }
        .buttonStyle(.plain)
        .disabled(!model.installed || model.busy)
        .help("停止应用的充电管理，并恢复接管前的系统设置")
        .frame(maxWidth: 1060, alignment: .leading)
        .padding(.horizontal, 22).padding(.top, 9).padding(.bottom, 20)
        .frame(maxWidth: .infinity)
    }

    private func batterySummary(width: CGFloat) -> some View {
        dashboardCard(title: "") {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.percentageText)
                        .font(.system(size: 34, weight: .semibold))
                        .tracking(-1.3)
                        .monospacedDigit()
                        .accessibilityLabel("电池电量 \(model.percentageText)")
                    Text(model.powerDisplay.title)
                        .font(.system(size: 12))
                        .foregroundStyle(CellmoriDesign.quiet)
                        .lineLimit(1)
                }
                .frame(width: max(78, (width - 34) / 3), alignment: .leading)
                BatteryMetrics()
            }
        }
    }

    private var dailyCharge: some View {
        dashboardCard(title: "", minHeight: 188) {
            HStack(spacing: 8) {
                Text("日常限充").font(.system(size: 14, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                rangeStatus
            }
            ChargeRangeEditor()
                .disabled(!model.chargeAvailable)
                .help(model.firmwareBackend
                      ? "达到上限后暂停，降到恢复点后回充。高于上限时，固件可能使用电池降至上限。"
                      : "达到上限后暂停，降到恢复点后再次充电。")
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Text(rangeNote).foregroundStyle(CellmoriDesign.quiet)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if model.hasChargeRangeDraft && !model.busy && !model.temporaryFlow {
                    Button("撤销修改", action: model.revertChargeRangeDraft)
                        .fixedSize(horizontal: true, vertical: false)
                        .help("恢复后台保存的充电范围")
                }
                if model.busy && !model.temporaryFlow && !model.limitApplied {
                    Button("应用中…") { model.apply(.limit) }
                        .buttonStyle(.borderedProminent).disabled(true)
                } else if !model.chargeAvailable {
                    Button(model.installed ? "检查后台" : "安装后台") { model.selectedPage = 2 }
                        .fixedSize(horizontal: true, vertical: false)
                } else if !model.limitApplied && !model.temporaryFlow {
                    Button("应用充电范围") { model.apply(.limit) }
                        .buttonStyle(.borderedProminent)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .font(.system(size: 12))
            .frame(minHeight: 26)
        }
    }

    @ViewBuilder private var rangeStatus: some View {
        Group {
            if !model.service.healthy || !model.live {
                Text(serviceCondition == .stale ? "后台无响应" : serviceCondition.title)
                    .foregroundStyle(serviceColor)
            } else if model.busy {
                Text("正在提交…").foregroundStyle(CellmoriDesign.quiet)
            } else if model.temporaryFlow {
                Text("临时任务中").foregroundStyle(CellmoriDesign.accent)
            } else if model.limitApplied {
                Label("已生效", systemImage: "checkmark").foregroundStyle(CellmoriDesign.good)
            } else if model.chargeAvailable && model.state?.error == nil {
                Label("待应用", systemImage: "circle").foregroundStyle(CellmoriDesign.quiet)
            } else {
                Text("生效待确认").foregroundStyle(CellmoriDesign.warning)
            }
        }.font(.system(size: 12))
    }

    private var rangeNote: String {
        guard let state = model.state, state.configuration.mode == .limit || model.temporaryFlow else {
            return model.chargeAvailable ? "按上方范围设置限充" : "充电范围待确认"
        }
        let config = state.configuration
        let prefix: String
        if state.error != nil {
            prefix = "已保存"
        } else if model.temporaryFlow {
            prefix = "日常范围"
        } else if !model.chargeAvailable {
            prefix = "上次读取"
        } else {
            prefix = "当前"
        }
        return "\(prefix) \(config.rechargeAt)%–\(config.target)%"
    }

    private var temporaryOperations: some View {
        dashboardCard(title: "临时操作", minHeight: 188) {
            if model.temporaryFlow {
                temporaryFlowDetail
            }
            operationRow("充满一次", icon: "bolt", enabled: model.fullAvailable) { model.apply(.full) }
            VStack(alignment: .leading, spacing: 7) {
                Label("接电放电", systemImage: "battery.25percent")
                    .foregroundStyle(CellmoriDesign.ink)
                    .labelStyle(ChargeActionLabel())
                HStack(spacing: 8) {
                    Slider(value: wholeNumber($model.dischargeTarget), in: 20...90)
                        .accessibilityLabel("放电目标")
                    Text("\(Int(model.dischargeTarget))%").monospacedDigit().frame(minWidth: 30)
                    Button("开始…") { model.confirm(.discharge) }
                        .disabled(!model.dischargeAvailable)
                }
                .padding(.leading, 21)
                .disabled(model.temporaryFlow || model.busy)
                .accessibilityElement(children: .contain)
            }.font(.callout)
            operationRow("电量校准", icon: "arrow.triangle.2.circlepath", enabled: model.dischargeAvailable) {
                model.confirm(.calibrate)
            }
            Toggle("放电期间保持唤醒（支持合盖）", isOn: $model.dischargeKeepAwake)
                .toggleStyle(.switch).controlSize(.small)
                .font(.caption).disabled(model.temporaryFlow || model.busy)
            DisclosureGroup("睡眠与放电说明") {
                Text("默认合盖或睡眠时暂停放电，唤醒并开盖后继续。开启保持唤醒后，电脑合盖时仍会运行，直至放电结束、暂停、停止或断电。")
                    .foregroundStyle(CellmoriDesign.quiet).padding(.top, 4)
            }.font(.caption).foregroundStyle(CellmoriDesign.quiet)
        }
    }

    private var temporaryFlowDetail: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(model.activeFlowTitle, systemImage: model.activeFlowSymbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(CellmoriDesign.accent)
            FlowSummary()
            HStack {
                Button(model.stopFlowTitle) { model.stopTemporaryFlow() }
                    .disabled(!model.canStopTemporaryFlow)
                if !model.busy && !model.canStopTemporaryFlow {
                    Button("检查后台") { model.selectedPage = 2 }.buttonStyle(.link)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(CellmoriDesign.accentWash, in: RoundedRectangle(cornerRadius: 8))
    }

    private func operationRow(_ title: String, icon: String, enabled: Bool, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: icon)
                .labelStyle(ChargeActionLabel())
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled || model.temporaryFlow || model.busy)
    }

    private struct ChargeActionLabel: LabelStyle {
        func makeBody(configuration: LabelStyleConfiguration) -> some View {
            HStack(spacing: 7) {
                configuration.icon
                    .foregroundStyle(CellmoriDesign.accent)
                    .frame(width: 14)
                configuration.title
            }
        }
    }

    private func dashboardCard<Content: View>(title: String, minHeight: CGFloat = 0,
                                               @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !title.isEmpty {
                Text(title).font(.system(size: 14, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            content()
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .background(CellmoriDesign.panel, in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13).strokeBorder(CellmoriDesign.line)
                .allowsHitTesting(false)
        }
    }

    var health: some View {
        VStack(spacing: 16) {
            dashboardCard(title: "电池健康检查") {
                if let b = model.battery {
                    HStack(spacing: 32) {
                        metric("系统最大容量", model.systemHealth)
                        metric("容量比估算", b.health.map { String(format: "%.1f%%", $0) } ?? "—")
                        metric("循环次数", "\(b.cycles)")
                        metric("电池温度", String(format: "%.1f °C", b.temperature))
                    }
                    Divider()
                    LabeledContent("当前满充容量估算 / 设计容量", value: "\(b.nominal) / \(b.design) mAh")
                    LabeledContent("电池电压", value: String(format: "%.3f V", b.voltage))
                    LabeledContent("电池电流（正数为充入）", value: String(format: "%+.0f mA", b.amperage))
                    LabeledContent("硬件故障标记", value: b.failure == 0 ? "未报告永久故障" : "异常：\(b.failure)")
                    Text("容量比估算来自当前满充容量 ÷ 设计容量，可能随温度和计量状态波动，与系统最大容量不同。未报告故障不代表通过完整硬件诊断。校准不修复化学损耗。")
                        .font(.caption).foregroundStyle(.secondary)
                } else { Text("暂无电池数据") }
            }
            dashboardCard(title: "最近 24 小时 · 电量") {
                let data = model.samples.filter { $0.date > Date().addingTimeInterval(-86400) }
                if data.count >= 2 {
                    Chart(data) { point in
                        AreaMark(x: .value("时间", point.date), y: .value("电量", point.percent)).foregroundStyle(CellmoriDesign.accent.opacity(0.10))
                        LineMark(x: .value("时间", point.date), y: .value("电量", point.percent)).foregroundStyle(CellmoriDesign.accent)
                    }.chartYScale(domain: 0...100).frame(height: 180)
                } else { trendEmpty(data.isEmpty ? "最近 24 小时暂无电量记录" : "正在积累电量记录") }
                HStack {
                    Text("本地保存最近 7 天；退出应用期间不采集历史。\n功率记录来自电池端，不等于整机功耗。").font(.caption).foregroundStyle(.secondary)
                    Spacer(); Button("导出 CSV") { model.export() }
                }
            }
            dashboardCard(title: "最近 24 小时 · 温度") {
                let data = model.samples.filter { $0.date > Date().addingTimeInterval(-86400) }
                if data.count >= 2 {
                    Chart(data) { point in
                        LineMark(x: .value("时间", point.date), y: .value("温度 °C", point.temperature)).foregroundStyle(.orange)
                    }.frame(height: 150)
                } else { trendEmpty(data.isEmpty ? "最近 24 小时暂无温度记录" : "正在积累温度记录") }
            }
        }
    }
    private func trendEmpty(_ title: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line").font(.title2).foregroundStyle(.tertiary)
            Text(title).font(.callout)
            Text("应用运行时每分钟记录一次，至少两条记录后显示趋势。")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, minHeight: 110)
    }
    func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title2.bold()).monospacedDigit() }
    }
    var servicePage: some View {
        VStack(spacing: 16) {
            dashboardCard(title: "后台服务") {
                HStack(spacing: 14) {
                    Image(systemName: [.running, .updateAvailable].contains(serviceCondition) ? "checkmark.shield.fill" : "gearshape.2.fill")
                        .font(.system(size: 33)).foregroundStyle(serviceColor)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(serviceCondition.title).font(.title3.bold())
                        Text(serviceIdentifier).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    }
                    Spacer()
                    if model.checkingService { ProgressView().controlSize(.small) }
                }
                Text(serviceCondition == .stale && model.service.healthy ? "进程最近没有有效响应，请重新检查后台。" : model.service.detail)
                    .font(.callout).foregroundStyle(CellmoriDesign.quiet)
                Divider()
                serviceRow("服务名称", value: serviceIdentifier, copy: true)
                serviceRow("启动域", value: "system/" + serviceIdentifier)
                serviceRow("进程 PID", value: model.service.pid.map(String.init) ?? "未运行")
                serviceRow("后台版本", value: model.service.state?.helperVersion.map { "v" + $0 } ?? "旧版（未上报）")
                serviceRow("应用版本", value: "v" + appVersion)
                serviceRow("睡眠控制", value: model.state?.sleepHoldActive == true ? (model.state?.error == nil ? "放电期间保持唤醒" : "恢复中，请查看错误") : "未接管")
                if let actual = model.state?.firmwareObserved {
                    serviceRow("固件实际上限", value: actual.activation == 2 ? "\(actual.upper)%（恢复充电：\(actual.lower)%）" : (model.state?.dischargeCommand == true ? "主动放电时暂时释放，结束或睡眠前恢复" : "未启用"))
                } else {
                    serviceRow("固件实际上限", value: "尚未读回确认")
                }
                HStack {
                    Text("最近响应").foregroundStyle(.secondary)
                    Spacer()
                    if let date = model.service.state?.updated {
                        Text(date, style: .relative).monospacedDigit()
                        Text("前").foregroundStyle(.secondary)
                    } else { Text("尚无响应") }
                }.font(.callout)
                HStack {
                    Text("检查时间").foregroundStyle(.secondary); Spacer()
                    Text(model.service.checkedAt.formatted(date: .omitted, time: .standard)).monospacedDigit()
                }.font(.callout)
                Divider()
                HStack(spacing: 12) {
                    Button("检查状态") { model.checkService(report: true) }.disabled(model.checkingService || model.busy)
                    Button("验证免密码通信") { model.admin(["ping"]) }.disabled(model.busy || model.state?.helperVersion != expectedHelperVersion)
                    Button(model.installed ? (model.service.condition == .updateAvailable ? "更新后台服务" : "修复 / 重新安装") : "安装后台服务") { model.admin([], install: true) }
                        .buttonStyle(.borderedProminent).disabled(model.busy)
                    Spacer()
                    Button("卸载…", role: .destructive) { model.uninstall() }.disabled(!model.installed || model.busy)
                }
            }
            dashboardCard(title: "安装检查") {
                checkRow("后台程序已安装", ok: model.service.binaryExists)
                checkRow("系统启动配置已安装", ok: model.service.plistExists)
                checkRow("launchd 进程正在运行", ok: model.service.registered && model.service.processRunning)
                checkRow("最近 65 秒内收到有效响应", ok: model.service.healthy && model.live)
                Text("安装后会自动核对进程、版本与首次响应；仅有程序文件不会显示安装成功。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            dashboardCard(title: "核对与诊断") {
                DisclosureGroup("查看程序位置和系统检查命令", isExpanded: $showFiles) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("后台程序\n" + helperPath)
                        Text("启动配置\n/Library/LaunchDaemons/" + serviceIdentifier + ".plist")
                        Text("终端检查\nlaunchctl print system/" + serviceIdentifier)
                    }.font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(.top, 12)
                }
                DisclosureGroup("硬件接口诊断", isExpanded: $showDiagnostics) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("可读接口不代表已获写入权限。固件限充与直接控制会自动选择适用后端。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("只读检测") { model.probe() }
                            Button("验证固件写权限") { model.admin(["firmware-test"]) }.disabled(!model.installed || model.busy)
                        }
                        Text("写权限验证仅将当前启用值原样写回，不修改目标或启动放电。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(model.probeText).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }.padding(.top, 12)
                }
                if let error = model.error ?? model.state?.error {
                    Button("查看最近错误…") { model.showErrorDetails(error) }
                }
            }
        }
    }
    func serviceRow(_ label: String, value: String, copy: Bool = false) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary); Spacer()
            Text(value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            if copy { Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("复制服务名称").accessibilityLabel("复制后台服务名称") }
        }.font(.callout)
    }
    func checkRow(_ label: String, ok: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ok ? CellmoriDesign.good : CellmoriDesign.quiet)
            Text(label).font(.callout); Spacer()
            Text(ok ? "通过" : "待确认").font(.caption).foregroundStyle(.secondary)
        }
    }
    func interfaceRow(_ label: String, bit: Int) -> some View {
        let known = model.live && model.state?.capabilities != nil
        let detected = known && (model.state?.capabilities ?? 0) & bit != 0
        return HStack(spacing: 10) {
            Image(systemName: detected ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(detected ? CellmoriDesign.good : CellmoriDesign.quiet)
            Text(label).font(.callout)
            Spacer()
            Text(!known ? "等待后台检测" : detected ? "已检测到" : "未检测到")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    var compatibility: some View {
        let capabilities = model.live && model.service.healthy && model.state?.helperVersion == expectedHelperVersion
            ? model.state?.capabilities : nil
        let supportsLimit = (capabilities ?? 0) & 5 != 0
        let supportsDischarge = supportsLimit && (capabilities ?? 0) & 2 != 0

        return VStack(spacing: 16) {
            dashboardCard(title: "本机功能") {
                capabilityRow("充电上限与充满一次", symbol: "battery.75percent", supported: capabilities.map { _ in supportsLimit })
                Divider()
                capabilityRow("接电放电与电量校准", symbol: "battery.25percent", supported: capabilities.map { _ in supportsDischarge })
                if capabilities == nil {
                    Button("查看后台服务") { model.selectedPage = 2 }
                } else if !supportsLimit {
                    Text("本机可继续查看电池状态。充电由 macOS 管理。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            dashboardCard(title: "设备信息") {
                LabeledContent("机型", value: model.machineModel)
                LabeledContent("系统", value: ProcessInfo.processInfo.operatingSystemVersionString)
            }
            dashboardCard(title: "系统电池设置") {
                Text("在 macOS 设置中查看电池健康与充电选项。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("打开系统电池设置") { model.openBatterySettings() }
            }
            dashboardCard(title: "诊断") {
                DisclosureGroup("硬件接口与固件版本") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("固件", value: model.firmwareVersion)
                        interfaceRow("固件限充", bit: 4)
                        interfaceRow("充电开关", bit: 1)
                        interfaceRow("适配器供电控制", bit: 2)
                        interfaceRow("物理电源检测", bit: 8)
                        Text("检测结果表示接口可读取，写入结果在执行操作时核对。")
                            .font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("原始检测结果") {
                            Text(model.probeText).font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled).padding(.top, 8)
                        }
                    }.padding(.top, 8)
                }
                HStack {
                    Button("刷新诊断") { model.probe(); model.checkService(); model.readDeviceSummary() }
                    Button("导出诊断报告…") { model.exportCompatibility() }
                }
            }
        }
    }
    private func capabilityRow(_ title: String, symbol: String, supported: Bool?) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if let supported {
                Label(supported ? "已检测到接口" : "未检测到所需接口",
                      systemImage: supported ? "checkmark.circle.fill" : "minus.circle")
                    .foregroundStyle(supported ? CellmoriDesign.good : CellmoriDesign.quiet)
            } else {
                Text("待检测").foregroundStyle(.secondary)
            }
        }.font(.callout)
    }
    var settings: some View {
        VStack(spacing: 16) {
            dashboardCard(title: "外观") {
                Picker("界面外观", selection: $model.appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }
            dashboardCard(title: "软件更新") { AppUpdateView(updater: model.updates) }
            dashboardCard(title: "温度保护") {
                HStack {
                    Label("温度阈值", systemImage: "thermometer.medium")
                    Slider(value: wholeNumber($model.temperatureLimit), in: 35...42)
                    Text("\(Int(model.temperatureLimit)) °C").monospacedDigit()
                }
                Text(model.firmwareBackend ? "固件模式下，达到阈值会暂停本应用流程并恢复原固件策略，不能直接切断充电。macOS 自身负责温控；降温 3°C 后继续。" : "达到阈值暂停充电，降温 3°C 后恢复。低于 5°C 暂停，回升至 8°C 后恢复。macOS 自身温控始终有效。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("更改阈值后，请在充电控制页重新应用策略。").font(.caption).foregroundStyle(.secondary)
            }
            dashboardCard(title: "启动与运行") {
                HStack {
                    Label("登录时启动", systemImage: "power")
                    Spacer()
                    Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled }, set: { value in
                        if value != model.loginEnabled { model.toggleLogin() }
                    })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                Divider()
                HStack {
                    Text("关闭面板后仍在程序坞显示")
                    Spacer()
                    Toggle("关闭面板后仍在程序坞显示", isOn: $model.showDockWhenPanelClosed)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                Text(model.showDockWhenPanelClosed ? "关闭面板后保留程序坞图标，可从程序坞再次打开。" : "关闭面板后隐藏程序坞图标，仅保留菜单栏。重新打开面板时恢复图标。")
                    .font(.caption).foregroundStyle(.secondary)
                if let last = model.lastClosedDockPolicy {
                    Text(last == "hidden" ? "最近关闭面板时：程序坞运行图标已隐藏。" : "最近关闭面板时：程序坞运行图标已保留。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("关闭窗口保留菜单栏。退出界面后，\(serviceIdentifier) 继续执行已保存的充电策略。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            dashboardCard(title: "控制方式") {
                LabeledContent("当前后端", value: model.firmwareBackend ? "固件限充" : "直接控制 / 待检测")
                Text(model.firmwareBackend ? "固件负责实际充放电，限充范围可在睡眠期间保留。超过上限时，固件可能使用电池降至目标。恢复系统管理会还原接管前设置。" : "后台每 15 秒检查一次电量。直接控制模式在睡眠前释放控制，睡眠期间可能超出上限。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("校准是充放电观察流程，不能修复化学损耗。请勿同时运行其他充电管理工具。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct MenuPopover: View {
    @EnvironmentObject var model: Model
    @Environment(\.openWindow) private var openWindow
    @State private var panelWindow = MenuPanelWindowReference()
    @State private var availableSize: CGSize?
    private let previewSize: CGSize?
    static let standardSize = CGSize(width: 384, height: 448)

    init(previewSize: CGSize? = nil) {
        self.previewSize = previewSize
    }

    private var size: CGSize { previewSize ?? availableSize ?? Self.standardSize }
    private var shortScreen: Bool { size.height < Self.standardSize.height }
    private var serviceNeedsAttention: Bool {
        !model.service.healthy || !model.live || model.state?.helperVersion != expectedHelperVersion
    }

    private func open(_ page: Int, temporaryOperations: Bool = false) {
        MenuPanelNavigation.openDashboard(from: panelWindow.window) {
            model.prepareToOpenPanel()
            model.selectedPage = page
            model.temporaryOperationsRequest = temporaryOperations ? UUID() : nil
        } show: {
            openWindow(id: "dashboard")
        } activate: {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            panelContent
            if shortScreen {
                HStack {
                    Spacer(minLength: 0)
                    operationAction
                }.frame(height: 26)
            }
            utilities
        }
        .padding(.horizontal, 16).padding(.vertical, shortScreen ? 14 : 27)
        .frame(width: size.width, height: size.height)
        .foregroundStyle(CellmoriDesign.ink).tint(CellmoriDesign.accent)
        .background(CellmoriDesign.surface)
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(CellmoriDesign.line).allowsHitTesting(false))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .preferredColorScheme(model.interfaceColorScheme)
        .background(InterfaceWindowCapture(reference: panelWindow, appearance: model.interfaceAppearance)
            .frame(width: 0, height: 0))
        .onAppear {
            guard previewSize == nil else { return }
            let pointer = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? panelWindow.window?.screen ?? NSScreen.main
            if let safeArea = screen?.visibleFrame {
                availableSize = CGSize(width: min(Self.standardSize.width, safeArea.width),
                                       height: min(Self.standardSize.height, safeArea.height - 14))
            }
        }
    }

    private var panelContent: some View {
        Group {
            if shortScreen {
                ScrollView { rows }
                    .scrollBounceBehavior(.basedOnSize)
            } else {
                rows
            }
        }
    }

    private var rows: some View {
        VStack(spacing: 10) {
            batteryHeader
            BatteryMetrics(rowSpacing: 1).frame(height: 36, alignment: .top)
            operation
            HStack(spacing: 8) {
                quickAction("充满一次", icon: "bolt", enabled: model.fullAvailable && !model.temporaryFlow) { model.apply(.full) }
                quickAction("放电与校准", icon: "slider.horizontal.3", enabled: true) { open(0, temporaryOperations: true) }
            }.frame(height: 32)
            serviceEntry
        }
    }

    private var batteryHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: model.powerDisplay == .external ? "battery.100percent.bolt" : model.powerDisplay.symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(CellmoriDesign.accent)
                .frame(width: 38, height: 38)
                .background(CellmoriDesign.accentWash, in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("电池").font(.system(size: 14, weight: .semibold))
                Text(model.powerDisplay.title).font(.system(size: 12)).foregroundStyle(CellmoriDesign.quiet)
            }
            Spacer(minLength: 8)
            Text(model.percentageText)
                .font(.system(size: 34, weight: .semibold)).tracking(-1.36).monospacedDigit()
                .accessibilityLabel("电池电量 \(model.percentageText)")
        }.frame(height: 48)
    }

    private var operation: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Text(model.temporaryFlow ? "临时操作" : "日常限充")
                    .font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                operationStatus
            }.frame(height: 18)
            Group {
                if model.temporaryFlow, let config = model.state?.configuration {
                    taskDetail(config)
                } else {
                    ChargeRangeEditor(compact: true)
                        .disabled(serviceNeedsAttention)
                }
            }.frame(height: 62, alignment: .top)
            HStack(spacing: 8) {
                Text(rangeNote).font(.system(size: 12)).foregroundStyle(CellmoriDesign.quiet)
                    .lineLimit(1).help(rangeNote)
                Spacer(minLength: 0)
                if model.hasChargeRangeDraft && !model.busy && !model.temporaryFlow {
                    policyButton("撤销修改", primary: false, perform: model.revertChargeRangeDraft)
                        .help("恢复后台保存的充电范围")
                }
                if !shortScreen { operationAction }
            }.frame(height: 26)
        }
        .padding(.horizontal, 12)
        .frame(height: 144)
        .background(CellmoriDesign.panel, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(CellmoriDesign.line).allowsHitTesting(false))
    }

    @ViewBuilder private var operationStatus: some View {
        Group {
            if model.busy {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini).accessibilityHidden(true)
                    Text("正在提交…")
                }.foregroundStyle(CellmoriDesign.quiet)
            } else if serviceNeedsAttention {
                Text(serviceStatus == .stale ? "后台无响应" : serviceStatus.title)
                    .foregroundStyle(CellmoriDesign.warning)
            } else if model.temporaryFlow {
                Text(taskStatus).foregroundStyle(CellmoriDesign.accent).help(model.status)
            } else if model.limitApplied {
                Label("已生效", systemImage: "checkmark").foregroundStyle(CellmoriDesign.good)
            } else if model.state?.error != nil || !model.chargeAvailable {
                Text("生效待确认").foregroundStyle(CellmoriDesign.warning)
            } else {
                Label("待应用", systemImage: "circle").foregroundStyle(CellmoriDesign.quiet)
            }
        }
        .font(.system(size: 12)).lineLimit(1)
    }

    private var taskStatus: String {
        guard let config = model.state?.configuration else { return model.activeFlowTitle }
        if model.state?.error != nil { return "策略待确认" }
        if config.thermalPaused { return "温度保护暂停" }
        if model.state?.battery?.external == false && model.powerDisplay != .external && model.powerDisplay != .charging {
            return "等待接通电源"
        }
        switch config.mode {
        case .full:
            return model.powerDisplay == .charging ? "充满一次 · 充电中" : "充满一次 · 等待充电"
        case .discharge:
            if config.dischargeKeepAwake != true || model.state?.sleepHoldActive != true {
                if model.battery?.lidClosed == true { return "放电已暂停" }
            }
            return model.powerDisplay == .battery && model.state?.dischargeCommand == true ? "放电中" : "等待切换供电"
        case .calibrate:
            return "校准中"
        default:
            return model.activeFlowTitle
        }
    }

    private func taskDetail(_ config: Configuration) -> some View {
        let detail = model.status + (model.state?.sleepHoldActive == true && !serviceNeedsAttention ? " · 保持唤醒" : "")
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                taskValue("当前电量", model.percentageText, alignment: .leading)
                Spacer(minLength: 0)
                taskValue("目标电量", taskTarget(config), alignment: .trailing)
            }
            Text(detail).font(.system(size: 11)).foregroundStyle(CellmoriDesign.quiet)
                .lineLimit(1).help(detail)
        }
    }

    private func taskValue(_ title: String, _ value: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(title).font(.system(size: 12)).foregroundStyle(CellmoriDesign.quiet)
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit()
        }.accessibilityElement(children: .combine)
    }

    private func taskTarget(_ config: Configuration) -> String {
        switch config.mode {
        case .full: return "100%"
        case .discharge: return "\(config.dischargeTarget)%"
        case .calibrate: return config.stage == "discharge" ? "20%" : "100%"
        default: return "—"
        }
    }

    private var rangeNote: String {
        guard let config = model.state?.configuration else { return "等待确认充电范围" }
        let range = "\(config.rechargeAt)%–\(config.target)%"
        if model.state?.error != nil { return "已保存 \(range)" }
        if model.temporaryFlow && !serviceNeedsAttention { return "结束后恢复 \(range)" }
        if model.temporaryFlow { return "已保存 \(range)" }
        guard config.mode == .limit else { return serviceNeedsAttention ? "等待确认充电范围" : "充电由系统管理" }
        if !serviceNeedsAttention { return "当前 \(range)" }
        return serviceStatus == .stale ? "上次确认 \(range)" : "上次读取 \(range)"
    }

    @ViewBuilder private var operationAction: some View {
        if model.busy {
            policyButton("提交中…", primary: true) {}.disabled(true)
        } else if serviceNeedsAttention || (!model.temporaryFlow && !model.chargeAvailable) {
            policyButton(model.installed ? "检查后台" : "安装后台", primary: false) { open(2) }
        } else if model.temporaryFlow {
            policyButton(model.stopFlowTitle, primary: true) { model.stopTemporaryFlow() }
                .disabled(!model.canStopTemporaryFlow)
        } else if !model.limitApplied {
            policyButton("应用充电范围", primary: true) { model.apply(.limit) }
        }
    }

    private func policyButton(_ title: String, primary: Bool, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title).font(.system(size: 12))
                .foregroundStyle(primary ? CellmoriDesign.onAccent : CellmoriDesign.ink)
                .padding(.horizontal, 9).frame(height: 25)
                .background(primary ? CellmoriDesign.accent : CellmoriDesign.rail, in: RoundedRectangle(cornerRadius: 6))
                .lineLimit(1)
        }
        .buttonStyle(PanelButtonStyle())
    }

    private func quickAction(_ title: String, icon: String, enabled: Bool, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: icon).font(.system(size: 12))
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CellmoriDesign.rail, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(CellmoriDesign.line).allowsHitTesting(false))
        }.buttonStyle(PanelButtonStyle()).disabled(!enabled || model.busy)
    }

    private var serviceStatus: ServiceCondition {
        model.service.healthy && !model.live ? .stale : model.service.condition
    }

    private var serviceEntry: some View {
        VStack(spacing: 0) {
            Rectangle().fill(CellmoriDesign.line).frame(height: 1)
            Button { open(2) } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("充电后台服务").font(.system(size: 14, weight: .semibold))
                        Text(serviceIdentifier).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(CellmoriDesign.quiet)
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 4) {
                        Circle().frame(width: 6, height: 6).accessibilityHidden(true)
                        Text(serviceStatus == .running ? "运行中" : serviceStatus == .stale ? "无响应" : serviceStatus.title)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(model.service.healthy && model.live ? CellmoriDesign.good :
                         serviceStatus == .checking ? CellmoriDesign.quiet : CellmoriDesign.warning)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(PanelButtonStyle())
            .help("查看充电后台服务详情")
        }.frame(height: 42)
    }

    private var utilities: some View {
        VStack(spacing: 5) {
            Rectangle().fill(CellmoriDesign.line).frame(height: 1)
            MenuUpdateControls(updater: model.updates) { open(3) } actions: {
                Button("控制面板") { open(0) }.help("打开控制面板")
            } exit: {
                Button("退出界面") { NSApp.terminate(nil) }.help("退出界面，后台继续运行")
            }
        }.frame(height: 42, alignment: .top)
    }

}
struct MenuUpdateControls<Actions: View, Exit: View>: View {
    @ObservedObject var updater: AppUpdater
    @State private var checkedFromMenu = false
    let openDetails: () -> Void
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var exit: () -> Exit

    private var showingResult: Bool { checkedFromMenu && !updater.busy }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                actions().frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    checkedFromMenu = true
                    updater.check(showErrorAlert: false)
                } label: {
                    if updater.checking {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini).accessibilityHidden(true)
                            Text("正在检查…")
                        }
                    } else {
                        Text("检查更新")
                    }
                }
                .disabled(updater.busy)
                .frame(maxWidth: .infinity)
                exit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            HStack(spacing: 6) {
                if showingResult {
                    Text(updater.status).foregroundStyle(CellmoriDesign.quiet)
                        .lineLimit(1).help(updater.status)
                }
                if let update = updater.available {
                    Button(action: openDetails) {
                        Text(showingResult ? "查看详情" : "发现新版 \(update.version) · 查看详情")
                    }
                    .accessibilityLabel("查看新版 \(update.version)")
                }
                Spacer(minLength: 0)
            }.frame(height: 16)
        }.font(.system(size: 12)).foregroundStyle(CellmoriDesign.accent).buttonStyle(PanelButtonStyle())
    }
}

private struct PanelButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label.opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.5)
    }
}

#if !SCREENSHOT_EXPORT
@main struct CellmoriApp: App {
    @StateObject private var model = Model()
    var body: some Scene {
        Window("Cellmori 电池管家", id: "dashboard") {
            Dashboard().environmentObject(model)
        }
        .defaultSize(width: 940, height: 700)
        .windowResizability(.contentMinSize)
        MenuBarExtra {
            MenuPopover().environmentObject(model)
        } label: {
            Image(nsImage: makeMenuBarIcon(percent: model.battery?.percent, state: model.powerDisplay))
                .interpolation(.high)
                .accessibilityLabel("Cellmori，\(model.powerDisplay.title)，电量 \(model.percentageText)")
                .help("\(model.powerDisplay.title) · \(model.percentageText)")
        }.menuBarExtraStyle(.window)
        .commands { CellmoriUpdateCommands(model: model) }
    }
}

struct CellmoriUpdateCommands: Commands {
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("设置…") {
                model.prepareToOpenPanel()
                model.selectedPage = 3
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }.keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .appInfo) {
            Button("检查更新…") {
                model.prepareToOpenPanel()
                model.selectedPage = 3
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
                model.updates.check()
            }
        }
    }
}

#endif
