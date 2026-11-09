// SPDX-License-Identifier: MIT
import Foundation
import IOKit
import IOKit.ps

let serviceDirectory = "/Library/Application Support/Cellmori"
let helperPath = "/Library/PrivilegedHelperTools/io.cellmori.helper"
let serviceIdentifier = "io.cellmori.helper"
let appVersion = "0.6.2"
let expectedHelperVersion = "0.6.2"
let statePath = serviceDirectory + "/state.json"
let configurationPath = serviceDirectory + "/configuration.json"

struct Battery: Codable {
    var percent: Double
    var temperature: Double
    var cycles: Int
    var design: Int
    var nominal: Int
    var voltage: Double
    var amperage: Double
    var external: Bool
    var charging: Bool
    var full: Bool
    var failure: Int
    var lidClosed: Bool? = nil
    var providingPowerSource: String? = nil
    var watts: Double { voltage * amperage / 1000 }
    var health: Double? { design > 0 && nominal > 0 ? Double(nominal) / Double(design) * 100 : nil }

    static func read() throws -> Battery {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard entry != 0 else { throw CMError.message("未找到内置电池") }
        defer { IOObjectRelease(entry) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let p = properties?.takeRetainedValue() as? [String: Any] else { throw CMError.message("读取电池信息失败") }
        func number(_ key: String) -> Double { (p[key] as? NSNumber)?.doubleValue ?? 0 }
        guard p["CurrentCapacity"] != nil, number("MaxCapacity") > 0, p["Temperature"] != nil,
              p["ExternalConnected"] != nil else { throw CMError.message("电池传感器数据不完整") }
        let raw = (p["Amperage"] as? NSNumber)?.uint64Value ?? 0
        let temp = number("Temperature") / 10 - 273.15
        let percent = number("CurrentCapacity") / number("MaxCapacity") * 100
        guard (0...100).contains(percent), (-20...90).contains(temp) else { throw CMError.message("电池传感器数值异常") }
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        var lidClosed: Bool? = nil
        if root != 0 {
            lidClosed = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
            IOObjectRelease(root)
        }
        var providingPowerSource: String? = nil
        if let snapshot=IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let source=IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() {
            providingPowerSource=source as String
        }
        return Battery(percent: percent, temperature: temp, cycles: Int(number("CycleCount")),
                       design: Int(number("DesignCapacity")), nominal: Int(number("NominalChargeCapacity")),
                       voltage: number("Voltage") / 1000, amperage: Double(Int64(bitPattern: raw)),
                       external: (p["AppleRawExternalConnected"] as? Bool) ?? (p["ExternalConnected"] as? Bool) ?? false,
                       charging: (p["IsCharging"] as? Bool) ?? false,
                       full: (p["FullyCharged"] as? Bool) ?? false, failure: Int(number("PermanentFailureStatus")), lidClosed: lidClosed,
                       providingPowerSource: providingPowerSource)
    }
}
enum CMError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
enum PowerDisplayState: CaseIterable {
    case charging, external, battery, unavailable
    static func resolve(_ b: Battery?) -> PowerDisplayState {
        guard let b else { return .unavailable }
        // Supply source and battery current describe different things. Match macOS's
        // declared source; a negative current alone must not imply battery supply.
        if b.providingPowerSource == "Battery Power" { return .battery }
        if b.providingPowerSource == "AC Power" {
            return b.charging ? .charging : .external
        }
        if b.charging { return .charging }
        return b.external ? .external : .battery
    }
    var title: String {
        switch self {
        case .charging: return "充电中"
        case .external: return "电源供电"
        case .battery: return "电池供电"
        case .unavailable: return "电池状态不可用"
        }
    }
    var symbol: String {
        switch self {
        case .charging: return "bolt.fill"
        case .external: return "powerplug.fill"
        case .battery: return "arrow.down.right"
        case .unavailable: return "questionmark"
        }
    }
}
enum Mode: String, Codable, CaseIterable {
    case system, limit, full, discharge, calibrate, adapterLimit
    var title: String {
        switch self {
        case .system: return "系统管理"
        case .limit: return "电量上限"
        case .full: return "临时充满"
        case .discharge: return "目标放电"
        case .calibrate: return "校准流程"
        case .adapterLimit: return "适配器兼容限充"
        }
    }
}
struct Configuration: Codable {
    var mode: Mode = .system
    var target: Int = 80
    var dischargeTarget: Int = 50
    var temperatureLimit: Double = 40
    var started: Date = Date()
    var stage: String = "charge"
    var stageStarted: Date = Date()
    var holdingSeconds: Double = 0
    var lastTick: Date? = nil
    var chargeAllowed: Bool = true
    var thermalPaused: Bool = false
    var ownsHardware: Bool = false
    var firmwareOriginal: FirmwareSettings? = nil
    var adapterFallback: Bool? = nil
}
struct FirmwareSettings: Codable, Equatable {
    var activation: Int
    var upper: Int
    var lower: Int
}
func firmwareSettings(for c: Configuration) -> FirmwareSettings {
    if c.thermalPaused, let original = c.firmwareOriginal { return original }
    if c.mode == .limit { return FirmwareSettings(activation: 2, upper: c.target, lower: c.target-5) }
    // Temporary full charge and calibration explicitly release the firmware limit.
    return FirmwareSettings(activation: 0, upper: 100, lower: 95)
}
func firmwareSleepSettings(for c: Configuration) -> FirmwareSettings {
    var upper=c.target
    if c.mode == .full || c.mode == .calibrate && c.stage != "discharge" { upper=100 }
    if c.mode == .discharge { upper=max(40,min(c.target,c.dischargeTarget)) }
    return FirmwareSettings(activation:2,upper:upper,lower:upper-5)
}
// Presentation only: never treat a submitted command as observed charging.
func temporaryFlowStatus(_ c: Configuration, battery b: Battery?) -> String? {
    guard [.full, .discharge, .calibrate].contains(c.mode) else { return nil }
    guard let b else { return "正在读取电池状态" }
    if c.thermalPaused { return "温度保护中，临时流程已暂停" }
    if !b.external && b.providingPowerSource != "AC Power" {
        return "等待接通电源，接通后继续"
    }
    if c.mode == .full {
        return b.charging ? "正在充电至 100%；完成后恢复日常上限" : "已解除本程序限充，等待系统开始充电"
    }
    if c.mode == .discharge {
        if b.lidClosed != false { return "放电已暂停，请保持开盖" }
        return b.providingPowerSource == "Battery Power"
            ? "放电流程进行中，目标 \(c.dischargeTarget)%"
            : "放电指令已提交，等待系统切换至电池供电"
    }
    if c.stage == "charge" || c.stage == "recharge" {
        return b.charging ? "校准：正在充电至 100%" : "校准：等待系统开始充电"
    }
    return nil
}
func limitSettingsApplied(_ c: Configuration?, target: Int, temperature: Double) -> Bool {
    guard let c, c.mode == .limit || c.mode == .adapterLimit else { return false }
    return c.target == target && c.temperatureLimit == temperature
}
struct ServiceState: Codable {
    var updated = Date()
    var configuration: Configuration
    var battery: Battery?
    var message: String
    var error: String?
    var chargeCommand: Bool?
    var dischargeCommand: Bool?
    var capabilities: Int? = nil
    var serviceName: String? = serviceIdentifier
    var helperVersion: String? = expectedHelperVersion
    var daemonPID: Int? = CommandLine.arguments.dropFirst().first == "serve" ? Int(ProcessInfo.processInfo.processIdentifier) : nil
}
struct Decision {
    var charge: Bool = true
    var discharge: Bool = false
    var message: String = "由 macOS 管理充电"
}

// Pure policy: no hardware access. Persisted state makes wake/relaunch transitions explicit.
func evaluate(_ config: inout Configuration, battery b: Battery, now: Date) -> Decision {
    let delta = min(30, max(0, now.timeIntervalSince(config.lastTick ?? now)))
    config.lastTick = now
    func finish(_ message: String) -> Decision {
        config.mode = .limit; config.chargeAllowed = b.percent < Double(config.target)
        return Decision(charge: config.chargeAllowed, message: message)
    }
    if config.mode == .system { return Decision() }
    if b.failure != 0 { config.mode = .system; return Decision(message: "电池故障标记：已恢复系统管理") }
    if [.full, .discharge, .calibrate].contains(config.mode), now.timeIntervalSince(config.started) > 48*3600 {
        config.mode = .system; return Decision(message: "操作超过 48 小时，已恢复系统管理")
    }
    if config.thermalPaused {
        if b.temperature <= config.temperatureLimit - 3 && b.temperature >= 8 { config.thermalPaused = false }
    } else if b.temperature >= config.temperatureLimit || b.temperature < 5 { config.thermalPaused = true }
    if config.thermalPaused {
        return Decision(charge: b.percent <= 20, message: b.percent <= 20 ? "低电量：恢复供电，macOS 温控继续生效" : "温度保护：暂停充电和主动放电")
    }
    if !b.external { return Decision(message: "使用电池中；接通电源后继续策略") }
    switch config.mode {
    case .system: return Decision()
    case .limit, .adapterLimit:
        if b.percent >= Double(config.target) { config.chargeAllowed = false }
        if b.percent <= Double(config.target - 5) { config.chargeAllowed = true }
        if config.mode == .adapterLimit {
            if b.percent <= 20 { config.chargeAllowed = true }
            if b.lidClosed != false { return Decision(message: "兼容限充已暂停：请开盖使用，已恢复外接供电") }
            return Decision(charge: config.chargeAllowed, discharge: !config.chargeAllowed,
                            message: config.chargeAllowed ? "兼容模式：接电充至 \(config.target)%" : "兼容模式：使用电池，降至 \(config.target-5)% 后恢复外接供电")
        }
        return Decision(charge: config.chargeAllowed, message: config.chargeAllowed ? "充电至 \(config.target)%" : "已暂停充电；低于 \(config.target-5)% 恢复")
    case .full:
        if b.full || b.percent >= 100 { return finish("临时充满完成，已恢复原上限") }
        return Decision(message: "临时充电至 100%")
    case .discharge:
        if b.percent <= Double(config.dischargeTarget) { return finish("目标放电完成，已恢复原上限") }
        if b.lidClosed != false { return Decision(charge: false, message: "放电已暂停：请开盖使用") }
        return Decision(charge: false, discharge: true, message: "接电放电至 \(config.dischargeTarget)%；请保持开盖")
    case .calibrate:
        switch config.stage {
        case "charge":
            if b.full || b.percent >= 100 { config.stage = "hold"; config.stageStarted = now; config.holdingSeconds = 0 }
            return Decision(message: "校准 1/4：充电至 100%")
        case "hold":
            if b.percent >= 99 { config.holdingSeconds += delta }
            if config.holdingSeconds >= 1800 { config.stage = "discharge"; config.stageStarted = now }
            return Decision(message: "校准 2/4：满电保持 \(Int(config.holdingSeconds/60))/30 分钟")
        case "discharge":
            if b.percent <= 20 { config.stage = "recharge"; config.stageStarted = now; return Decision(message: "校准 4/4：充回 100%") }
            if now.timeIntervalSince(config.stageStarted) > 12*3600 { config.mode = .system; return Decision(message: "校准放电超时，已恢复系统管理") }
            if b.lidClosed != false { return Decision(charge: false, message: "校准放电已暂停：请开盖使用") }
            return Decision(charge: false, discharge: true, message: "校准 3/4：放电至 20%；请保持开盖")
        case "recharge":
            if b.full || b.percent >= 100 { return finish("校准流程完成，已恢复原上限；请观察后续容量趋势") }
            return Decision(message: "校准 4/4：充回 100%")
        default: config.mode = .system; return Decision(message: "校准状态异常，已恢复系统管理")
        }
    }
}

func encode<T: Encodable>(_ value: T, path: String) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: URL(fileURLWithPath: path), options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
}
func decode<T: Decodable>(_ type: T.Type, path: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(contentsOf: URL(fileURLWithPath: path)))
}
