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
        live && state?.error == nil && limitSettingsApplied(
            state?.configuration, target: Int(target), temperature: temperatureLimit, rechargeGap: rechargeGap
        )
    }
    var activeFlowTitle: String { state?.configuration.mode.title ?? "临时流程" }
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
        if preview { return }

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
        guard temporaryFlow, let c = state?.configuration, service.healthy else { return }
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
        if alert.runModal() == .alertFirstButtonReturn { admin([], uninstall: true) }
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

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? Color.white : Color.secondary)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(enabled ? cellmoriAccent.opacity(configuration.isPressed ? 0.8 : 1) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct SoftButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        SoftButtonSurface(configuration: configuration, selected: selected)
    }
}

private struct SoftButtonSurface: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    var body: some View {
        configuration.label
            .foregroundStyle(selected ? cellmoriAccent : Color.primary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(selected ? cellmoriAccent.opacity(configuration.isPressed ? 0.18 : 0.10) : Color.primary.opacity(configuration.isPressed ? 0.10 : hovered && enabled ? 0.06 : 0.025), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? cellmoriAccent.opacity(0.16) : Color.primary.opacity(0.045)))
            .opacity(enabled ? 1 : 0.42)
            .onHover { hovered = $0 }
    }
}

struct ChargeRangeEditor: View {
    @EnvironmentObject var model: Model
    @Environment(\.isEnabled) private var enabled

    private enum Endpoint: Hashable { case lower, upper }
    @FocusState private var focused: Endpoint?
    @State private var dragging: Endpoint?
    @State private var lowerAtDragStart: Int?

    private let scale = 20...100
    private let inset: CGFloat = 11
    private var upper: Int { Int(model.target) }
    private var lower: Int { model.rechargeAt }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                endpointLabel("恢复充电", percent: lower, alignment: .leading)
                Spacer(minLength: 12)
                endpointLabel("充电上限", percent: upper, alignment: .trailing)
            }
            .accessibilityHidden(true)
            GeometryReader { geometry in
                let width = max(1, geometry.size.width - 2 * inset)
                let left = position(lower, width: width)
                let right = position(upper, width: width)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                        .frame(width: width, height: 5).offset(x: inset)
                    Capsule().fill(cellmoriAccent)
                        .frame(width: max(1, right - left), height: 5).offset(x: left)
                    thumb(.lower, x: left)
                    thumb(.upper, x: right)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { change in
                        guard enabled, !model.busy, !model.temporaryFlow else { return }
                        if dragging == nil {
                            let start = change.startLocation.x
                            dragging = abs(start - left) <= abs(start - right) ? .lower : .upper
                            lowerAtDragStart = lower
                            focused = dragging
                        }
                        if let dragging {
                            let fraction = min(1, max(0, (change.location.x - inset) / width))
                            let percent = scale.lowerBound + Int((fraction * Double(scale.upperBound - scale.lowerBound)).rounded())
                            set(dragging, to: percent)
                        }
                    }
                    .onEnded { _ in dragging = nil; lowerAtDragStart = nil })
            }
            .frame(height: 26)
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
    }

    private func endpointLabel(_ title: String, percent: Int, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("\(percent)%").font(.system(size: 22, weight: .semibold)).monospacedDigit()
        }
    }

    private func position(_ percent: Int, width: CGFloat) -> CGFloat {
        inset + width * Double(percent - scale.lowerBound) / Double(scale.upperBound - scale.lowerBound)
    }

    private func thumb(_ endpoint: Endpoint, x: CGFloat) -> some View {
        Circle().fill(Color(nsColor: .controlBackgroundColor))
            .overlay(Circle().strokeBorder(cellmoriAccent, lineWidth: focused == endpoint ? 3 : 1.5))
            .frame(width: 17, height: 17)
            .offset(x: x - 8.5)
            .focusable()
            .focused($focused, equals: endpoint)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { adjust(endpoint, by: -1) }
            .onKeyPress(.rightArrow) { adjust(endpoint, by: 1) }
    }

    private func adjust(_ endpoint: Endpoint, by amount: Int) -> KeyPress.Result {
        set(endpoint, to: (endpoint == .lower ? lower : upper) + amount)
        return .handled
    }

    private func set(_ endpoint: Endpoint, to percent: Int) {
        if endpoint == .lower {
            model.rechargeGap = upper - rechargeThreshold(percent, upper: upper)
        } else {
            let newUpper = min(100, max(40, percent))
            let newLower = rechargeThreshold(lowerAtDragStart ?? lower, upper: newUpper)
            model.target = Double(newUpper)
            model.rechargeGap = newUpper - newLower
        }
    }
}

struct ChargeRangeStatus: View {
    let lower: Int
    let upper: Int
    let applied: Bool

    var body: some View {
        Label {
            Text("\(lower)%–\(upper)% · \(applied ? "已生效" : "待应用")")
                .foregroundStyle(applied ? .primary : .secondary)
        } icon: {
            Image(systemName: applied ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(applied ? Color.green : .secondary)
        }.font(.system(size: 12, weight: .medium))
    }
}

struct Card<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !title.isEmpty { Text(title).font(.system(size: 14, weight: .semibold)) }
            content
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.055)))
    }
}

struct BatteryGlyph: View {
    var fraction: Double
    var charging: Bool
    var body: some View {
        HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.035))
                RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.16), lineWidth: 1.5)
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: 9)
                        .fill((fraction <= 0.2 ? Color.red : charging ? Color.green : cellmoriAccent).gradient)
                        .frame(width: max(0, (g.size.width-12) * min(1,max(0,fraction))))
                        .padding(6)
                }
                if charging { Image(systemName: "bolt.fill").font(.system(size: 25, weight: .semibold)).foregroundStyle(.white).frame(maxWidth: .infinity) }
            }
            Capsule().fill(Color.primary.opacity(0.18)).frame(width: 5, height: 20)
        }.frame(width: 112, height: 62)
        .accessibilityElement(children: .ignore).accessibilityLabel("电池电量 \(Int(fraction*100))%")
    }
}

struct ServiceBadge: View {
    @EnvironmentObject var model: Model
    var compact = false
    var color: Color { model.service.healthy ? .green : model.service.condition == .checking ? .secondary : .orange }
    var body: some View {
        HStack(spacing: 6) {
            if model.checkingService && model.service.condition == .checking { ProgressView().controlSize(.mini) }
            else { Circle().fill(color).frame(width: 7, height: 7) }
            Text(compact ? (model.service.healthy ? "后台运行中" : model.service.condition.title) : model.service.condition.title)
                .font(.caption.weight(.medium))
        }.padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(color).background(color.opacity(0.075), in: Capsule())
            .help("\(serviceIdentifier) · \(model.service.detail)")
    }
}

struct Dashboard: View {
    @EnvironmentObject var model: Model
    @State private var showFiles = false
    @State private var showDiagnostics = false
    private let teal = cellmoriAccent
    private let titles = ["充电控制", "健康与趋势", "后台服务", "偏好设置", "设备支持"]
    private let symbols = ["battery.75percent", "heart.text.square", "gearshape.2", "slider.horizontal.3", "checkmark.shield"]
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.shield.fill")
                        .font(.system(size: 21, weight: .medium)).foregroundStyle(cellmoriAccent)
                        .frame(width: 38, height: 38)
                        .background(cellmoriAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Cellmori").font(.system(size: 15, weight: .semibold))
                        Text("电池管理").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 18)
                List(selection: $model.selectedPage) {
                    Section("电池") {
                        ForEach(0..<2, id: \.self) { index in sidebarItem(index) }
                    }
                    Section("应用") {
                        ForEach(2..<titles.count, id: \.self) { index in sidebarItem(index) }
                    }
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 9) {
                    Button { model.selectedPage = 2 } label: { ServiceBadge(compact: true) }.buttonStyle(.plain)
                    Text(serviceIdentifier).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    Text("版本 \(appVersion)").font(.caption).foregroundStyle(.tertiary)
                }.padding(18)
            }.navigationSplitViewColumnWidth(min: 185, ideal: 200, max: 230)
        } detail: {
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(titles[model.selectedPage]).font(.system(size: 25, weight: .semibold))
                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !model.service.healthy {
                        Button { model.selectedPage = 2 } label: { ServiceBadge() }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 26).padding(.top, 24).padding(.bottom, 20)
                ScrollView {
                    VStack(spacing: 16) {
                        switch model.selectedPage {
                        case 0: controls
                        case 1: health
                        case 2: servicePage
                        case 3: settings
                        default: compatibility
                        }
                    }.padding(.horizontal, 28).padding(.bottom, 28)
                }
                Divider()
                HStack(spacing: 8) {
                    if model.busy { ProgressView().controlSize(.mini) }
                    else { Image(systemName: model.notice == nil ? "info.circle" : "checkmark.circle").foregroundStyle(model.notice == nil ? Color.secondary : .green) }
                    Text(model.busy ? "正在提交操作…" : (model.notice ?? (model.selectedPage == 0 ? model.status : "数据仅保存在本机")))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    Spacer(minLength: 0)
                    if model.notice != nil && !model.busy { Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭提示") }
                }.padding(.horizontal, 20).padding(.vertical, 12).frame(minHeight: 42)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 800, idealWidth: 900, minHeight: 680, idealHeight: 780)
        .background(Color(nsColor: .windowBackgroundColor)).tint(cellmoriAccent)
        .onAppear { model.prepareToOpenPanel() }
    }
    private func sidebarItem(_ index: Int) -> some View {
        Label {
            Text(titles[index]).font(.system(size: 13))
        } icon: {
            Image(systemName: symbols[index]).symbolRenderingMode(.hierarchical)
                .foregroundStyle(cellmoriAccent)
        }.padding(.vertical, 4).tag(index)
    }
    var subtitle: String {
        switch model.selectedPage {
        case 0: return "日常限充与临时充放电"
        case 1: return "了解电池状态与使用趋势"
        case 2: return "确认服务身份、安装与运行状态"
        case 3: return "调整电池养护和启动选项"
        default: return "查看本机充电功能、系统信息与诊断"
        }
    }
    var controls: some View {
        VStack(spacing: 16) {
            Card(title: "") {
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.percentageText).font(.system(size: 50, weight: .medium)).tracking(-2).monospacedDigit()
                        Label(model.powerDisplay.title, systemImage: model.powerDisplay.symbol)
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(model.powerDisplay.interfaceColor)
                    }
                    Spacer(minLength: 0)
                    BatteryGlyph(fraction: (model.battery?.percent ?? 0)/100, charging: model.powerDisplay == .charging)
                }
                HStack(spacing: 12) {
                    batteryMetric("温度", value: model.battery.map { String(format: "%.1f °C", $0.temperature) } ?? "—", icon: "thermometer.medium")
                    batteryMetric("电池功率", value: model.battery.map { String(format: "%+.1f W", $0.watts) } ?? "—", icon: "bolt")
                    batteryMetric("电池健康", value: model.systemHealth, icon: "heart")
                }
            }
            if model.temporaryFlow {
                Card(title: model.activeFlowTitle) {
                    Text(model.status).font(.callout)
                    HStack {
                        Text("停止后恢复已保存的 \(model.state?.configuration.target ?? 80)% 日常上限").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(model.stopFlowTitle) { model.stopTemporaryFlow() }.disabled(model.busy || !model.service.healthy)
                    }
                }
            }
            Card(title: "日常充电范围") {
                ChargeRangeEditor()
                HStack {
                    if !model.temporaryFlow {
                        ChargeRangeStatus(lower: model.rechargeAt, upper: Int(model.target), applied: model.limitApplied)
                    }
                    Spacer()
                    if model.busy {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("正在提交…").font(.caption) }
                    } else if model.temporaryFlow {
                        Text("临时流程进行中").font(.caption).foregroundStyle(.secondary)
                    } else if !model.limitApplied {
                        Button("应用充电范围") { model.apply(.limit) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.chargeAvailable)
                    }
                }
                Text(model.firmwareBackend ? "固件决定实际充放电；高于上限时可能自动使用电池降至目标。" : "达到上限后暂停，低于回充下限后恢复充电。")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.installed {
                    Divider()
                    HStack { Text("先安装后台服务以启用充电管理").font(.callout).foregroundStyle(.secondary); Spacer(); Button("安装服务") { model.selectedPage = 2 } }
                } else if !model.service.healthy {
                    Divider()
                    HStack { Text("后台服务需要检查").font(.callout).foregroundStyle(.secondary); Spacer(); Button("查看状态") { model.selectedPage = 2 } }
                }
            }
            Card(title: "临时操作") {
                HStack(spacing: 12) {
                    action("充满一次", icon: "battery.100percent", enabled: model.fullAvailable && !model.temporaryFlow) { model.apply(.full) }
                    action("电量校准", icon: "arrow.triangle.2.circlepath", enabled: model.dischargeAvailable && !model.temporaryFlow) { model.confirm(.calibrate) }
                    action("交还系统管理", icon: "arrow.uturn.backward", enabled: model.installed) { model.admin(["reset"]) }
                }
                Divider()
                HStack {
                    Label("接电放电至", systemImage: "battery.25percent")
                    Slider(value: wholeNumber($model.dischargeTarget), in: 20...90).frame(maxWidth: 180).accessibilityLabel("放电目标")
                    Text("\(Int(model.dischargeTarget))%").monospacedDigit().frame(width: 35)
                    Spacer(minLength: 0)
                    Button("开始…") { model.confirm(.discharge) }.disabled(!model.dischargeAvailable || model.busy || model.temporaryFlow)
                }.font(.callout)
                Toggle("放电期间保持唤醒（支持合盖）", isOn: $model.dischargeKeepAwake)
                    .toggleStyle(.switch).controlSize(.small).disabled(model.temporaryFlow || model.busy)
                Text(model.dischargeKeepAwake ? "主动放电时临时禁止系统睡眠，合盖后电脑仍在运行。结束、暂停、停止或断电后恢复原睡眠设置。" : "默认关闭：合盖或睡眠时暂停主动放电，唤醒并开盖后继续。")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("使用说明") {
                    Text("临时流程可随时停止并恢复日常上限。“交还系统管理”会停止所有流程，恢复接管前设置；退出界面后后台仍继续运行。未开启保持唤醒时，主动放电请保持开盖；最低保留 20%。")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    func batteryMetric(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 14, weight: .medium, design: .rounded)).monospacedDigit()
            }
            Spacer(minLength: 0)
        }.padding(12).frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
    }
    func action(_ text: String, icon: String, enabled: Bool, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 16, weight: .medium)).foregroundStyle(cellmoriAccent)
                Text(text).font(.system(size: 12, weight: .medium))
            }.frame(maxWidth: .infinity).padding(.vertical, 7)
        }.buttonStyle(SoftButtonStyle()).disabled(!enabled || model.busy)
    }
    var health: some View {
        VStack(spacing: 16) {
            Card(title: "电池健康检查") {
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
            Card(title: "最近 24 小时 · 电量") {
                let data = model.samples.filter { $0.date > Date().addingTimeInterval(-86400) }
                if data.count >= 2 {
                    Chart(data) { point in
                        AreaMark(x: .value("时间", point.date), y: .value("电量", point.percent)).foregroundStyle(teal.opacity(0.10))
                        LineMark(x: .value("时间", point.date), y: .value("电量", point.percent)).foregroundStyle(teal)
                    }.chartYScale(domain: 0...100).frame(height: 180)
                } else { trendEmpty(data.isEmpty ? "最近 24 小时暂无电量记录" : "正在积累电量记录") }
                HStack {
                    Text("本地保存最近 7 天；退出应用期间不采集历史。\n功率记录来自电池端，不等于整机功耗。").font(.caption).foregroundStyle(.secondary)
                    Spacer(); Button("导出 CSV") { model.export() }
                }
            }
            Card(title: "最近 24 小时 · 温度") {
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
            Card(title: "后台服务") {
                HStack(spacing: 14) {
                    Image(systemName: model.service.healthy ? "checkmark.shield.fill" : "gearshape.2.fill")
                        .font(.system(size: 33)).foregroundStyle(model.service.healthy ? Color.green : cellmoriAccent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.service.condition.title).font(.title3.bold())
                        Text(serviceIdentifier).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    }
                    Spacer()
                    if model.checkingService { ProgressView().controlSize(.small) }
                }
                Text(model.service.detail).font(.callout).foregroundStyle(.secondary)
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
            Card(title: "安装检查") {
                checkRow("后台程序已安装", ok: model.service.binaryExists)
                checkRow("系统启动配置已安装", ok: model.service.plistExists)
                checkRow("launchd 进程正在运行", ok: model.service.registered && model.service.processRunning)
                checkRow("最近 65 秒内收到有效响应", ok: model.service.healthy)
                Text("安装后会自动核对进程、版本与首次响应；仅有程序文件不会显示安装成功。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Card(title: "核对与诊断") {
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
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ok ? Color.green : .secondary)
            Text(label).font(.callout); Spacer()
            Text(ok ? "通过" : "待确认").font(.caption).foregroundStyle(.secondary)
        }
    }
    func interfaceRow(_ label: String, bit: Int) -> some View {
        let known = model.live && model.state?.capabilities != nil
        let detected = known && (model.state?.capabilities ?? 0) & bit != 0
        return HStack(spacing: 10) {
            Image(systemName: detected ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(detected ? Color.green : .secondary)
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
            Card(title: "本机功能") {
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
            Card(title: "设备信息") {
                LabeledContent("机型", value: model.machineModel)
                LabeledContent("系统", value: ProcessInfo.processInfo.operatingSystemVersionString)
            }
            Card(title: "系统电池设置") {
                Text("在 macOS 设置中查看电池健康与充电选项。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("打开系统电池设置") { model.openBatterySettings() }
            }
            Card(title: "诊断") {
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
                    .foregroundStyle(supported ? Color.green : .secondary)
            } else {
                Text("待检测").foregroundStyle(.secondary)
            }
        }.font(.callout)
    }
    var settings: some View {
        VStack(spacing: 16) {
            Card(title: "软件更新") { AppUpdateView(updater: model.updates) }
            Card(title: "温度保护") {
                HStack {
                    Label("温度阈值", systemImage: "thermometer.medium")
                    Slider(value: wholeNumber($model.temperatureLimit), in: 35...42)
                    Text("\(Int(model.temperatureLimit)) °C").monospacedDigit()
                }
                Text(model.firmwareBackend ? "固件模式下，达到阈值会暂停本应用流程并恢复原固件策略，不能直接切断充电。macOS 自身负责温控；降温 3°C 后继续。" : "达到阈值暂停充电，降温 3°C 后恢复。低于 5°C 暂停，回升至 8°C 后恢复。macOS 自身温控始终有效。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("更改阈值后，请在充电控制页重新应用策略。").font(.caption).foregroundStyle(.secondary)
            }
            Card(title: "启动与运行") {
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
            Card(title: "控制方式") {
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
    @Environment(\.openWindow) var openWindow
    @State private var panelWindow = MenuPanelWindowReference()
    func open(_ page: Int) {
        MenuPanelNavigation.openDashboard(from: panelWindow.window) {
            model.prepareToOpenPanel()
            model.selectedPage = page
        } show: {
            openWindow(id: "dashboard")
        } activate: {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            batterySummary
            if model.temporaryFlow {
                activeFlow
            } else {
                limitControl
            }
            HStack(spacing: 8) {
                quickAction("充满一次", icon: "battery.100percent", enabled: model.fullAvailable && !model.temporaryFlow) { model.apply(.full) }
                quickAction("放电与校准", icon: "slider.horizontal.3", enabled: true) { open(0) }
            }
            footer
        }
        .padding(17).frame(width: 384).tint(cellmoriAccent)
        .background(.regularMaterial)
        .background(MenuPanelWindowCapture(reference: panelWindow).frame(width: 0, height: 0))
    }
    private var batterySummary: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 11) {
                Image(systemName: model.powerDisplay.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(model.powerDisplay.interfaceColor)
                    .frame(width: 38, height: 38)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("电池").font(.headline)
                    Text(model.powerDisplay.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.percentageText)
                    .font(.system(size: 36, weight: .semibold)).monospacedDigit()
                    .accessibilityLabel("电池电量 \(model.percentageText)")
            }
            HStack(spacing: 0) {
                smallMetric("温度", value: model.battery.map { String(format:"%.1f°", $0.temperature) } ?? "—", icon: "thermometer.medium")
                Spacer(minLength: 8)
                smallMetric("电池功率", value: model.battery.map { String(format:"%+.1f W", $0.watts) } ?? "—", icon: "bolt")
                Spacer(minLength: 8)
                smallMetric("健康", value: model.systemHealth, icon: "heart")
            }
        }.padding(.horizontal, 2)
    }
    private func smallMetric(_ name: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(name, systemImage: icon).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .medium)).monospacedDigit().lineLimit(1)
        }.accessibilityElement(children: .combine)
    }
    private var limitControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("日常限充", systemImage: "shield.lefthalf.filled").font(.headline)
                Spacer()
                if model.chargeAvailable && !model.busy {
                    Label(model.limitApplied ? "已生效" : "待应用",
                          systemImage: model.limitApplied ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.caption).foregroundStyle(model.limitApplied ? Color.green : .secondary)
                }
            }
            ChargeRangeEditor()
            if model.busy {
                HStack(spacing: 7) { ProgressView().controlSize(.small); Text("正在提交操作…").font(.callout) }
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
            } else if !model.chargeAvailable {
                VStack(spacing: 6) {
                    Text("充电管理暂不可用").font(.callout)
                    Button("查看后台与可用功能") { open(2) }.buttonStyle(.link)
                }.frame(maxWidth: .infinity).padding(.vertical, 5)
            } else {
                if !model.limitApplied {
                    if model.live, let saved = model.state?.configuration, saved.mode == .limit {
                        Text("当前范围 \(saved.rechargeAt)%–\(saved.target)%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button { model.apply(.limit) } label: {
                        Text("应用充电范围").font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(PrimaryButtonStyle())
                }
            }
        }.padding(15)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Color.primary.opacity(0.075)))
    }
    private var activeFlow: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(model.activeFlowTitle, systemImage: model.state?.configuration.mode == .discharge ? "battery.25percent" : "battery.100percent").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(model.stopFlowTitle) { model.stopTemporaryFlow() }.font(.system(size: 12, weight: .medium)).buttonStyle(.bordered).controlSize(.small)
                    .disabled(model.busy || !model.service.healthy)
            }
            Text(model.status).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let config = model.state?.configuration {
                HStack(spacing: 6) {
                    Text("结束后恢复 \(config.rechargeAt)%–\(config.target)%")
                    if model.state?.sleepHoldActive == true {
                        Text("· 保持唤醒中")
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(13).background(cellmoriAccent.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }
    private func quickAction(_ title: String, icon: String, enabled: Bool, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity).padding(.vertical, 3)
        }.buttonStyle(SoftButtonStyle()).disabled(!enabled || model.busy)
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.65)
            Button { open(2) } label: {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "gearshape.2").foregroundStyle(.secondary)
                        .frame(width: 19).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("充电管理后台").font(.callout.weight(.medium))
                        Text(serviceIdentifier).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary).padding(.top, 1)
                    }
                    Spacer(minLength: 4)
                    ServiceBadge(compact: true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("查看充电管理后台详情")
            MenuUpdateControls(updater: model.updates) { open(3) } actions: {
                Button { open(0) } label: {
                    Label("控制面板", systemImage: "macwindow")
                }.help("打开控制面板")
            } exit: {
                Button { NSApp.terminate(nil) } label: {
                    Label("退出界面", systemImage: "power")
                }.help("退出界面，后台继续运行")
            }
        }
    }

}
#if !SCREENSHOT_EXPORT
@main struct CellmoriApp: App {
    @StateObject private var model = Model()
    var body: some Scene {
        Window("Cellmori 电池管家", id: "dashboard") {
            Dashboard().environmentObject(model)
        }.defaultSize(width: 900, height: 780)
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
