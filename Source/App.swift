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
    @Published var dischargeTarget: Double = 50
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
    var adapterMode: Bool { state?.configuration.mode == .adapterLimit && state?.configuration.adapterFallback == true }
    var firmwareBackend: Bool { !adapterMode && (state?.capabilities ?? 0) & 4 != 0 }
    var chargeAvailable: Bool { installed && live && service.healthy && ((state?.capabilities ?? 0) & 5 != 0 || adapterMode && (state?.capabilities ?? 0) & 10 == 10) }
    var fullAvailable: Bool { chargeAvailable && !adapterMode }
    var dischargeAvailable: Bool { fullAvailable && (state?.capabilities ?? 0) & 2 != 0 }
    var canEnableAdapterMode: Bool {
        service.healthy && state?.error == nil && service.state?.helperVersion == expectedHelperVersion && (state?.capabilities ?? 0) & 10 == 10 && (state?.capabilities ?? 0) & 5 == 0
    }
    var temporaryFlow: Bool { state.map { [.full, .discharge, .calibrate].contains($0.configuration.mode) } ?? false }
    var limitApplied: Bool { live && state?.error == nil && limitSettingsApplied(state?.configuration, target: Int(target), temperature: temperatureLimit) }
    var limitButtonTitle: String { temporaryFlow ? "请先停止临时流程" : limitApplied ? "已应用" : "应用上限" }
    var activeFlowTitle: String { state?.configuration.mode.title ?? "临时流程" }
    var stopFlowTitle: String {
        switch state?.configuration.mode {
        case .discharge: return "停止放电"
        case .full: return "取消充满一次"
        default: return "停止校准"
        }
    }
    var nativeLimitEligible: Bool {
        let os=ProcessInfo.processInfo.operatingSystemVersion
        return os.majorVersion>26 || os.majorVersion==26 && os.minorVersion>=4
    }
    var status: String {
        guard installed else { return "只读监测 · 尚未安装后台服务" }
        guard live else { return "后台状态过期，请检查服务" }
        if state?.error != nil { return "系统管理 · 最近操作未完成" }
        var flowBattery = battery
        // The helper uses independent physical AC detection, unlike the raw flag
        // which can disappear when this app deliberately cuts adapter power.
        if let physical = state?.battery?.external { flowBattery?.external = physical }
        if let c = state?.configuration, let flow = temporaryFlowStatus(c, battery: flowBattery) { return flow }
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
        // Wake and adapter switching can publish several successive hardware states.
        // Notifications are primary; brief polling also covers delayed publication.
        transitionRefresh = Task { @MainActor [weak self] in
            for _ in 0..<15 {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
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
        do { battery = try Battery.read(); lastBatteryError = nil }
        catch {
            battery = nil
            if lastBatteryError != error.localizedDescription { self.error = error.localizedDescription; lastBatteryError = error.localizedDescription }
        }
        state = try? decode(ServiceState.self, path: statePath)
        if live, let issue = state?.error {
            if lastBackendError != issue { lastBackendError = issue; error = issue }
        } else if state?.error == nil { lastBackendError = nil }
        if !loadedSettings, let c = state?.configuration {
            target = Double(c.target); dischargeTarget = Double(c.dischargeTarget); temperatureLimit = c.temperatureLimit
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
        alert.messageText = "操作未完成"; alert.informativeText = message
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
        let effective = mode == .limit && adapterMode ? Mode.adapterLimit : mode
        if effective == .adapterLimit && service.state?.helperVersion != expectedHelperVersion {
            error="请先更新后台服务，才能使用适配器兼容模式。";selectedPage=2;return
        }
        guard !temporaryFlow else { error = "请先停止当前临时流程，再开始新的操作。"; return }
        // Starting a temporary flow must preserve the applied daily limit, not an unsaved draft.
        let saved = state?.configuration
        let dailyTarget = [.full, .discharge, .calibrate].contains(mode) ? saved?.target ?? Int(target) : Int(target)
        let thermal = [.full, .discharge, .calibrate].contains(mode) ? saved?.temperatureLimit ?? temperatureLimit : temperatureLimit
        admin(["configure", effective.rawValue, String(dailyTarget), String(Int(thermal)), String(Int(dischargeTarget))])
    }
    func stopTemporaryFlow() {
        guard temporaryFlow, let c = state?.configuration, service.healthy else { return }
        admin(["configure", Mode.limit.rawValue, String(c.target), String(Int(c.temperatureLimit)), String(c.dischargeTarget)])
    }
    func enableAdapterMode() {
        guard canEnableAdapterMode else { error="当前不满足适配器兼容模式条件：需要新版后台、适配器控制和物理电源检测，且普通充电接口不可用。";return }
        let alert=NSAlert();alert.alertStyle = .warning;alert.messageText="启用适配器兼容限充？"
        alert.informativeText="电量达到 \(Int(target))% 时切换为电池供电，降至 \(Int(target)-5)% 时恢复外接供电。\n\n这会造成电量往返变化，仅在开盖且系统清醒时维持；睡眠和合盖时恢复外接供电，可能充过上限。临时充满、手动放电和校准在此模式下不可用。系统原有充电限制仍可能生效。\n\n不会自动启用此模式，可随时恢复系统管理退出。"
        alert.addButton(withTitle:"启用兼容模式");alert.addButton(withTitle:"取消")
        if alert.runModal() == .alertFirstButtonReturn { apply(.adapterLimit) }
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

struct Card<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !title.isEmpty { Text(title).font(.headline) }
            content
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.05)))
    }
}

let cellmoriAccent = Color(red: 0.96, green: 0.47, blue: 0.16)

struct BatteryGlyph: View {
    var fraction: Double
    var charging: Bool
    var body: some View {
        HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.14), lineWidth: 3)
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: 7).fill(cellmoriAccent.gradient)
                        .frame(width: max(4, (g.size.width-12) * min(1,max(0,fraction))))
                        .padding(6)
                }
                if charging { Image(systemName: "bolt.fill").font(.system(size: 27, weight: .semibold)).foregroundStyle(.white).frame(maxWidth: .infinity) }
            }
            RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.16)).frame(width: 6, height: 22)
        }.frame(width: 112, height: 62)
        .accessibilityLabel("电池电量 \(Int(fraction*100))%")
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
            .background(color.opacity(0.09), in: Capsule())
            .help("\(serviceIdentifier) · \(model.service.detail)")
    }
}

struct Dashboard: View {
    @EnvironmentObject var model: Model
    @State private var targetText = "80"
    @State private var showFiles = false
    @State private var showDiagnostics = false
    private let teal = cellmoriAccent
    private let titles = ["充电控制", "健康与趋势", "后台服务", "偏好设置", "兼容性"]
    private let symbols = ["battery.75percent", "heart.text.square", "gearshape.2", "slider.horizontal.3", "checkmark.shield"]
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.batteryblock.fill").font(.system(size: 27)).foregroundStyle(cellmoriAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cellmori").font(.headline)
                        Text("电池管家").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 12).padding(.top, 24).padding(.bottom, 22)
                ForEach(0..<titles.count, id: \.self) { index in
                    Button {
                        model.selectedPage = index
                    } label: {
                        Label(titles[index], systemImage: symbols[index])
                            .font(.system(size: 13, weight: model.selectedPage == index ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
                            .foregroundStyle(model.selectedPage == index ? cellmoriAccent : .primary)
                            .background(model.selectedPage == index ? cellmoriAccent.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain)
                }
                Spacer()
                Divider().padding(.bottom, 12)
                Button { model.selectedPage = 2 } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        ServiceBadge(compact: true)
                        Text(serviceIdentifier).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).padding(.horizontal, 8)
                Text("版本 \(appVersion)").font(.caption2).foregroundStyle(.tertiary).padding(8)
            }.padding(.horizontal, 10).padding(.bottom, 12).frame(width: 170).background(.regularMaterial)
            Divider()
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(titles[model.selectedPage]).font(.system(size: 25, weight: .bold))
                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.selectedPage = 2 } label: { ServiceBadge() }.buttonStyle(.plain)
                }.padding(24)
                ScrollView {
                    VStack(spacing: 16) {
                        switch model.selectedPage {
                        case 0: controls
                        case 1: health
                        case 2: servicePage
                        case 3: settings
                        default: compatibility
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 24)
                }
                Divider()
                HStack(spacing: 8) {
                    if model.busy { ProgressView().controlSize(.mini) }
                    else { Image(systemName: model.notice == nil ? "info.circle" : "checkmark.circle").foregroundStyle(model.notice == nil ? Color.secondary : .green) }
                    Text(model.busy ? (model.notice ?? "正在等待系统操作…") : (model.notice ?? model.status))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    Spacer(minLength: 0)
                    if model.notice != nil && !model.busy { Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭提示") }
                }.padding(.horizontal, 20).padding(.vertical, 12).frame(minHeight: 42)
            }
        }
        .frame(minWidth: 800, idealWidth: 860, minHeight: 680, idealHeight: 760)
        .background(Color(nsColor: .windowBackgroundColor)).tint(cellmoriAccent)
        .onAppear { targetText = String(Int(model.target)); model.prepareToOpenPanel() }
        .onChange(of: model.target) { _, value in targetText = String(Int(value)) }
    }
    var subtitle: String {
        switch model.selectedPage {
        case 0: return "日常限充与临时充放电"
        case 1: return "了解电池状态与使用趋势"
        case 2: return "确认服务身份、安装与运行状态"
        case 3: return "调整电池养护和启动选项"
        default: return "macOS 26 接口诊断与可选兼容方案"
        }
    }
    func validateTarget() -> Bool {
        guard let value = Int(targetText), (40...100).contains(value) else {
            model.error = "请输入 40 到 100 之间的整数作为充电上限。"
            targetText = String(Int(model.target)); return false
        }
        model.target = Double(value); return true
    }
    var draftLimitApplied: Bool { Int(targetText) == Int(model.target) && model.limitApplied }
    var controls: some View {
        VStack(spacing: 16) {
            Card(title: "") {
                HStack(spacing: 24) {
                    BatteryGlyph(fraction: (model.battery?.percent ?? 0)/100, charging: model.powerDisplay == .charging)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.percentageText).font(.system(size: 42, weight: .semibold, design: .rounded))
                        Label(model.powerDisplay.title, systemImage: model.powerDisplay.symbol)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Divider()
                HStack {
                    Label(model.battery.map { String(format: "%.1f °C", $0.temperature) } ?? "— °C", systemImage: "thermometer.medium")
                    Spacer()
                    Label(model.battery.map { String(format: "%+.1f W", $0.watts) } ?? "— W", systemImage: "bolt")
                    Spacer()
                    Label(model.systemHealth, systemImage: "heart")
                }.font(.callout).foregroundStyle(.secondary).monospacedDigit()
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
            Card(title: "充电上限") {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.adapterMode ? "适配器兼容限充" : model.firmwareBackend ? "固件限充" : "日常限充").font(.callout.weight(.medium))
                        Text("回充范围 \(Int(model.target)-5)%–\(Int(model.target))%").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    TextField("上限", text: $targetText).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                        .font(.system(size: 38, weight: .semibold, design: .rounded)).frame(width: 86)
                        .accessibilityLabel("充电上限百分比").onSubmit { _ = validateTarget() }
                    Text("%").font(.title2).foregroundStyle(.secondary)
                }
                Slider(value: $model.target, in: 40...100, step: 1).accessibilityLabel("充电上限")
                HStack {
                    ForEach([60, 80, 90, 100], id: \.self) { n in
                        Button("\(n)%") { model.target = Double(n) }.buttonStyle(.bordered).controlSize(.small)
                    }
                    Spacer()
                    Button(model.temporaryFlow ? "请先停止临时流程" : draftLimitApplied ? "已应用" : "应用上限") { if validateTarget() { model.apply(.limit) } }.buttonStyle(.borderedProminent)
                        .tint(draftLimitApplied || model.temporaryFlow ? Color.gray : cellmoriAccent)
                        .disabled(!model.chargeAvailable || model.busy || draftLimitApplied || model.temporaryFlow)
                }
                Text(model.adapterMode ? "达到上限切换为电池供电，降至下限恢复外接供电。睡眠、合盖时暂停，可能超出上限。" : model.firmwareBackend ? "固件决定实际充放电；高于上限时可能自动使用电池降至目标。" : "达到上限后暂停，低于回充下限后恢复充电。")
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
                    Slider(value: $model.dischargeTarget, in: 20...90, step: 1).frame(maxWidth: 180).accessibilityLabel("放电目标")
                    Text("\(Int(model.dischargeTarget))%").monospacedDigit().frame(width: 35)
                    Spacer(minLength: 0)
                    Button("开始…") { model.confirm(.discharge) }.disabled(!model.dischargeAvailable || model.busy || model.temporaryFlow)
                }.font(.callout)
                Text("临时流程可随时停止并恢复日常上限。“交还系统管理”会停止所有流程，恢复接管前设置；退出界面后后台仍继续运行。主动放电请保持开盖，最低保留 20%。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    func action(_ text: String, icon: String, enabled: Bool, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 8) { Image(systemName: icon).font(.system(size: 21)); Text(text).font(.callout) }
                .frame(maxWidth: .infinity).padding(.vertical, 11)
        }.buttonStyle(.bordered).disabled(!enabled || model.busy)
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
                } else { Text("运行应用后每分钟采样一次，积累两条记录后显示趋势。") .foregroundStyle(.secondary).frame(height: 120) }
                HStack {
                    Text("本地保存最近 7 天；退出应用期间不采集历史。\n功率记录来自电池端，不等于整机功耗。").font(.caption).foregroundStyle(.secondary)
                    Spacer(); Button("导出 CSV") { model.export() }
                }
            }
            Card(title: "最近 24 小时 · 温度") {
                if model.samples.count >= 2 {
                    Chart(model.samples.filter { $0.date > Date().addingTimeInterval(-86400) }) { point in
                        LineMark(x: .value("时间", point.date), y: .value("温度 °C", point.temperature)).foregroundStyle(.orange)
                    }.frame(height: 150)
                } else { Text("正在积累温度记录…").foregroundStyle(.secondary) }
            }
        }
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
            if copy { Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("复制服务名称") }
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
        VStack(spacing:16) {
            Card(title:"当前环境") {
                LabeledContent("系统",value:ProcessInfo.processInfo.operatingSystemVersionString)
                LabeledContent("机型",value:model.machineModel)
                LabeledContent("固件",value:model.firmwareVersion)
                Text("macOS 26 的功能取决于实际固件和写权限，不能仅凭系统版本判断。用户已报告在 MacBook Pro（M4）/ macOS 26 上完成全部功能验证，芯片为 M4，系统小版本未提供。其他设备仍需实际检测。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Card(title:"自动探测的充电接口") {
                interfaceRow("充电开关接口", bit: 1)
                Text("直接开启或暂停充电。不是每台 Mac 都有，本机不需要依赖它才能限充。")
                    .font(.caption).foregroundStyle(.secondary)
                interfaceRow("电量上限接口（固件限充）", bit: 4)
                Text("把上限交给电脑内部执行，例如达到 79% 后停止充电。")
                    .font(.caption).foregroundStyle(.secondary)
                interfaceRow("适配器控制接口", bit: 2)
                interfaceRow("独立物理电源检测", bit: 8)
                if model.live, let capabilities = model.state?.capabilities, capabilities & 4 != 0, !model.adapterMode {
                    Text(model.state?.configuration.mode == .system
                         ? "本机已检测到电量上限接口，可用于日常限充。目前由系统管理。"
                         : "当前使用电量上限接口管理限充，无需充电开关接口。")
                        .font(.callout)
                }
                Text("“已检测到”表示接口可读取，写入是否成功会在执行操作时核对。“未检测到”不表示缺少管理员授权，也不表示全部功能不可用。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {Button("刷新诊断") {model.probe();model.checkService();model.readDeviceSummary()};Button("导出兼容性报告…") {model.exportCompatibility()}}
                DisclosureGroup("查看原始探测结果") {Text(model.probeText).font(.system(.caption,design:.monospaced)).textSelection(.enabled).padding(.top,8)}
            }
            Card(title:"适配器兼容模式 · 实验性") {
                Text("用于充电接口被固件限制、但适配器仍可控的情况。通过外接供电与电池供电之间切换维持范围，会产生电量往返变化。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("仅开盖、清醒时有效；睡眠或合盖恢复供电。此模式不支持临时充满、手动放电和校准，也不能保证绕过系统原有限充。常规充电功能已有 macOS 26 用户实机反馈；本实验模式仍需单独核对。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.adapterMode {
                    Label("已手动启用",systemImage:"checkmark.circle").foregroundStyle(.orange)
                    Button("退出兼容模式 / 恢复系统管理") {model.admin(["reset"])}.disabled(model.busy)
                } else {
                    Button("手动启用兼容模式…") {model.enableAdapterMode()}.disabled(!model.canEnableAdapterMode || model.busy)
                    Text(model.service.state?.helperVersion != expectedHelperVersion ? "请先在后台服务页升级控制服务。" : (model.state?.capabilities ?? 0)&5 != 0 ? "当前普通充电接口可用，无需启用兼容模式。" : "需要可用的适配器控制与独立电源检测接口。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Card(title:"系统原生限充") {
                Text("Apple Silicon Mac 从 macOS 26.4 起提供 80%–100% 系统限充。本程序提供设置入口，不调用或模拟苹果私有原生限充 API。")
                    .font(.callout).foregroundStyle(.secondary)
                Text(model.nativeLimitEligible ? "当前系统版本满足条件，请在系统设置中确认可用选项。" : "当前系统版本尚不满足 macOS 26.4 条件。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("打开系统电池设置") {model.openBatterySettings()}
                Link("Apple 功能说明",destination:URL(string:"https://support.apple.com/en-my/102338")!)
            }
        }
    }
    var settings: some View {
        VStack(spacing: 16) {
            Card(title: "软件更新") { AppUpdateView(updater: model.updates) }
            Card(title: "温度保护") {
                HStack {
                    Label("温度阈值", systemImage: "thermometer.medium")
                    Slider(value: $model.temperatureLimit, in: 35...42, step: 1)
                    Text("\(Int(model.temperatureLimit)) °C").monospacedDigit()
                }
                Text(model.firmwareBackend ? "固件模式下，达到阈值会暂停本应用流程并恢复原固件策略，不能直接切断充电。macOS 自身负责温控；降温 3°C 后继续。" : "达到阈值暂停充电，降温 3°C 后恢复。低于 5°C 暂停，回升至 8°C 后恢复。macOS 自身温控始终有效。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("更改阈值后，请在充电控制页重新应用策略。").font(.caption).foregroundStyle(.secondary)
            }
            Card(title: "启动与运行") {
                HStack { Label("登录时启动", systemImage: "power"); Spacer(); Button(model.loginEnabled ? "关闭登录启动" : "开启登录启动") { model.toggleLogin() } }
                Divider()
                Toggle("关闭面板后仍在程序坞显示", isOn: $model.showDockWhenPanelClosed)
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
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "bolt.batteryblock.fill").foregroundStyle(cellmoriAccent)
                Text("Cellmori").font(.headline)
                Spacer()
                Button { open(2) } label: { ServiceBadge(compact: true) }.buttonStyle(.plain)
            }
            HStack(spacing: 18) {
                BatteryGlyph(fraction: (model.battery?.percent ?? 0)/100, charging: model.powerDisplay == .charging).scaleEffect(0.75).frame(width: 88, height: 50)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.percentageText).font(.system(size: 33, weight: .semibold, design: .rounded))
                    Label(model.powerDisplay.title, systemImage: model.powerDisplay.symbol).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()
            HStack { Text("充电上限").font(.callout); Spacer(); Text("\(Int(model.target))%").font(.title3.bold()).monospacedDigit() }
            Slider(value: $model.target, in: 40...100, step: 1).accessibilityLabel("充电上限")
            HStack {
                Button(model.limitButtonTitle) { model.apply(.limit) }.buttonStyle(.borderedProminent)
                    .tint(model.limitApplied || model.temporaryFlow ? Color.gray : cellmoriAccent)
                    .disabled(!model.chargeAvailable || model.busy || model.limitApplied || model.temporaryFlow)
                Button("充满一次") { model.apply(.full) }.disabled(!model.fullAvailable || model.busy || model.temporaryFlow)
                Button { open(0) } label: { Image(systemName: "ellipsis") }.help("更多充电操作")
            }
            if model.temporaryFlow {
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                Button(model.stopFlowTitle + "并恢复日常上限") { model.stopTemporaryFlow() }.disabled(model.busy || !model.service.healthy)
            }
            HStack {
                Text(serviceIdentifier).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                Spacer(); Button("详情") { open(2) }.buttonStyle(.link)
            }
            UpdateMenuButton(updater: model.updates) { open(3) }
            Divider()
            HStack {
                Button { open(0) } label: { Label("打开面板", systemImage: "rectangle.on.rectangle") }
                Spacer()
                Button { open(3) } label: { Image(systemName: "gearshape") }.help("偏好设置")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("退出界面，后台继续运行")
            }.buttonStyle(.plain).font(.callout)
            if model.busy { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
        }.padding(18).frame(width: 360).tint(cellmoriAccent)
            .background(MenuPanelWindowCapture(reference: panelWindow).frame(width: 0, height: 0))
    }
}
#if !SCREENSHOT_EXPORT
@main struct CellmoriApp: App {
    @StateObject private var model = Model()
    var body: some Scene {
        Window("Cellmori 电池管家", id: "dashboard") {
            Dashboard().environmentObject(model)
        }.defaultSize(width: 860, height: 760)
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
