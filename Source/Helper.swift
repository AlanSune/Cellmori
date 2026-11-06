// SPDX-License-Identifier: MIT
import Foundation
import Darwin

@main struct Helper {
    private static var sleeping = false
    static func main() {
        do {
            if CommandLine.arguments.dropFirst().first == "serve" { try serve() }
            else { try run() }
        } catch {
            FileHandle.standardError.write(Data(((error.localizedDescription) + "\n").utf8))
            exit(1)
        }
    }
    static func logged(_ args: [String]) {
        do { try run(args) } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)) }
    }
    static func powerChanged(_ event: Int32) {
        sleeping = event == 0
        logged([sleeping ? "prepare-sleep" : "tick"])
    }
    static func serve() throws {
        guard geteuid() == 0 else { throw CMError.message("后台服务需要管理员权限") }
        guard cm_watch_power({ event in Helper.powerChanged(event) }) == 0 else {
            try? run(["reset"])
            throw CMError.message("无法监听系统睡眠，已尝试恢复充电，停止后台控制")
        }
        let control = try ControlServer { arguments in
            if arguments == ["ping"] { return "\(serviceIdentifier) · v\(expectedHelperVersion) · PID \(getpid()) · 已验证本地通信" }
            try run(arguments)
            return "操作已完成"
        }
        logged(["tick"])
        let timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            if !sleeping { logged(["tick"]) }
        }
        withExtendedLifetime((timer, control)) { RunLoop.current.run() }
    }
    static func hardware(_ decision: Decision) throws {
        var buffer = [CChar](repeating: 0, count: 512)
        let result = cm_control(decision.charge ? 1 : 0, decision.discharge ? 1 : 0, &buffer, Int32(buffer.count))
        guard result == 0 else { throw CMError.message(String(cString: buffer)) }
    }
    static func restore() throws {
        var buffer = [CChar](repeating: 0, count: 512)
        guard cm_restore(&buffer, Int32(buffer.count)) == 0 else { throw CMError.message(String(cString: buffer)) }
    }
    static func readFirmware() throws -> FirmwareSettings {
        var a:Int32=0,u:Int32=0,l:Int32=0
        var buffer=[CChar](repeating:0,count:512)
        guard cm_firmware_read(&a,&u,&l,&buffer,Int32(buffer.count))==0 else { throw CMError.message(String(cString:buffer)) }
        return FirmwareSettings(activation:Int(a),upper:Int(u),lower:Int(l))
    }
    static func setFirmware(_ settings: FirmwareSettings) throws {
        var buffer=[CChar](repeating:0,count:512)
        guard cm_firmware_set(Int32(settings.activation),Int32(settings.upper),Int32(settings.lower),&buffer,Int32(buffer.count))==0 else {
            throw CMError.message(String(cString:buffer))
        }
    }
    static func adapter(_ discharge: Bool) throws {
        var buffer=[CChar](repeating:0,count:512)
        guard cm_adapter(discharge ? 1:0,&buffer,Int32(buffer.count))==0 else { throw CMError.message(String(cString:buffer)) }
    }
    static func restoreManaged(_ config: Configuration) throws {
        if config.adapterFallback == true { try adapter(false); return }
        if let original=config.firmwareOriginal {
            var errors:[String]=[]
            do { try setFirmware(original) } catch { errors.append(error.localizedDescription) }
            if cm_capabilities() & 2 != 0 {
                do { try adapter(false) } catch { errors.append(error.localizedDescription) }
            }
            if !errors.isEmpty {throw CMError.message(errors.joined(separator:"; "))}
        } else { try restore() }
    }
    static func run(_ arguments: [String]? = nil) throws {
        let args = arguments ?? Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { throw CMError.message("Usage: helper probe | status | configure MODE TARGET TEMPERATURE DISCHARGE_TARGET | tick | reset") }
        if command == "probe" {
            var buffer = [CChar](repeating: 0, count: 1024)
            let result = cm_probe(&buffer, Int32(buffer.count))
            print(String(cString: buffer)); if result != 0 { exit(2) }; return
        }
        if command == "status" {
            let e = JSONEncoder(); e.outputFormatting = .prettyPrinted
            print(String(data: try e.encode(Battery.read()), encoding: .utf8)!); return
        }
        guard geteuid() == 0 else { throw CMError.message("电源控制需要管理员权限，请从应用授权安装后台服务。") }
        guard ["configure", "tick", "reset", "prepare-sleep", "prepare-update", "firmware-test"].contains(command) else { throw CMError.message("未知命令") }
        // Installer owns this directory. No user-supplied paths or arbitrary commands.
        var directoryStat = stat()
        guard lstat(serviceDirectory, &directoryStat) == 0, directoryStat.st_uid == 0,
              directoryStat.st_mode & 0o022 == 0, directoryStat.st_mode & S_IFMT == S_IFDIR else {
            throw CMError.message("服务数据目录权限不安全，请重新安装")
        }
        let fd = open(serviceDirectory + "/lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CMError.message("无法创建配置锁") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CMError.message("无法锁定配置") }
        defer { flock(fd, LOCK_UN) }
        var config: Configuration
        if FileManager.default.fileExists(atPath: configurationPath) {
            do { config = try decode(Configuration.self, path: configurationPath) }
            catch {
                try restore()
                config = Configuration()
                try encode(config, path: configurationPath)
                try encode(ServiceState(configuration: config, message: "配置损坏，已恢复系统管理", error: error.localizedDescription), path: statePath)
                throw CMError.message("配置损坏，已恢复供电，请重新设置")
            }
        } else { config = Configuration() }
        if command == "firmware-test" {
            guard config.mode == .system && !config.ownsHardware else { throw CMError.message("请先恢复系统管理再验证固件权限") }
            var buffer=[CChar](repeating:0,count:1024)
            let result=cm_test_firmware_access(&buffer,Int32(buffer.count))
            let report=String(cString:buffer)
            try encode(["report":report,"time":ISO8601DateFormatter().string(from:Date())],path:serviceDirectory+"/firmware-access.json")
            guard result==0 else { throw CMError.message(report) }
            print(report);return
        }
        if command == "prepare-sleep" || command == "prepare-update" {
            if config.ownsHardware {
                do {
                    if config.firmwareOriginal != nil && config.adapterFallback != true && config.mode != .system && command == "prepare-sleep" {
                        // Keep a firmware ceiling while asleep instead of restoring an
                        // originally-disabled limit and allowing the battery to recharge.
                        try setFirmware(firmwareSleepSettings(for:config))
                        if cm_capabilities() & 2 != 0 { try adapter(false) }
                    } else { try restoreManaged(config) }
                } catch {
                    try encode(ServiceState(configuration: config, message: "睡眠前恢复供电失败，请检查连接", error: error.localizedDescription), path: statePath)
                    throw error
                }
                let message = command == "prepare-update" ? "正在更新后台，现有策略已保留" : config.firmwareOriginal != nil && config.adapterFallback != true && config.mode != .system ? "系统即将睡眠，固件保留 \(firmwareSleepSettings(for:config).upper)% 上限；唤醒后恢复流程" : "系统即将睡眠，已释放供电控制；唤醒后恢复策略"
                try encode(ServiceState(configuration: config, battery: try? Battery.read(), message: message, chargeCommand: true, dischargeCommand: false, capabilities:Int(cm_capabilities())), path: statePath)
            }
            return
        }
        if command == "reset" {
            config.mode = .system
            // Persist reset intent first: next tick retries even if the hardware write fails.
            try encode(config, path: configurationPath)
            do {
                if config.ownsHardware { try restoreManaged(config) }
                config.ownsHardware = false
                config.firmwareOriginal = nil
                config.adapterFallback = nil
                try encode(config, path: configurationPath)
                try encode(ServiceState(configuration: config, battery: try? Battery.read(), message: "已解除所有控制，恢复系统管理", capabilities: Int(cm_capabilities())), path: statePath)
            } catch {
                try encode(ServiceState(configuration: config, message: "恢复供电失败，后台将重试", error: error.localizedDescription), path: statePath)
                throw error
            }
            return
        }
        if command == "configure" {
            guard args.count == 5, let mode = Mode(rawValue: args[1]), let target = Int(args[2]),
                  let temperature = Double(args[3]), let discharge = Int(args[4]),
                  (40...100).contains(target), (35...42).contains(temperature), (20...90).contains(discharge) else {
                throw CMError.message("参数无效：上限 40–100，温控 35–42，放电目标 20–90")
            }
            // Validate sensor and key capability before persisting a new active policy.
            _ = try Battery.read()
            if mode == .adapterLimit {
                guard cm_capabilities() & 10 == 10, cm_physical_power() >= 0 else {
                    throw CMError.message("适配器控制或物理电源检测不可用，不能启用兼容模式")
                }
            } else if mode != .system {
                var buffer = [CChar](repeating: 0, count: 1024)
                guard cm_probe(&buffer, Int32(buffer.count)) == 0 else {
                    throw CMError.message("本机充电接口未通过检测：" + String(cString: buffer))
                }
                if [.discharge, .calibrate].contains(mode), cm_capabilities() & 2 == 0 {
                    throw CMError.message("本机不支持接电放电，不能启动该流程")
                }
            }
            if config.adapterFallback == true && mode != .adapterLimit && mode != .system {
                throw CMError.message("请先恢复系统管理，再使用普通限充、临时充满或校准。兼容模式不支持这些临时流程。")
            }
            if mode == .adapterLimit && config.adapterFallback != true && config.ownsHardware {
                try restoreManaged(config); config.ownsHardware=false; config.firmwareOriginal=nil
            }
            if mode == .adapterLimit { config.adapterFallback=true }
            config.mode = mode; config.target = target; config.temperatureLimit = temperature
            config.dischargeTarget = discharge; config.started = Date(); config.stage = "charge"
            config.stageStarted = Date(); config.holdingSeconds = 0; config.lastTick = nil
            config.chargeAllowed = true; config.thermalPaused = false
            try encode(config, path: configurationPath)
        }
        do {
            var battery = try Battery.read()
            let physical=cm_physical_power()
            if config.adapterFallback == true {
                guard physical>=0 else { throw CMError.message("物理电源检测失败，正在退出兼容模式并恢复供电") }
            }
            // Adapter cut can alter the smart-battery AC flags; prefer independent physical
            // presence for all control flows, not only compatibility mode.
            if physical>=0 { battery.external = physical==1 }
            var decision = evaluate(&config, battery: battery, now: Date())
            let capabilities=cm_capabilities()
            if config.mode == .system {
                if config.ownsHardware { try restoreManaged(config); config.ownsHardware = false }
                config.firmwareOriginal=nil;config.adapterFallback=nil
            } else {
                if config.adapterFallback != true && capabilities & 4 != 0 && config.firmwareOriginal == nil { config.firmwareOriginal=try readFirmware() }
                config.ownsHardware = true
                try encode(config, path: configurationPath)
                if config.adapterFallback == true {
                    try adapter(decision.discharge)
                    if config.thermalPaused { decision.message="兼容流程因温度暂停，已恢复外接供电；系统继续负责温控" }
                } else if capabilities & 4 != 0 {
                    if capabilities & 2 != 0 && !decision.discharge { try adapter(false) }
                    try setFirmware(firmwareSettings(for:config))
                    if decision.discharge { try adapter(true) }
                    if config.thermalPaused { decision.message="温度保护：流程已暂停，已恢复原固件策略；macOS 负责温控" }
                    else if config.mode == .limit { decision.message="固件限充 \(config.target-5)%–\(config.target)%；充放电由固件决定" }
                    decision.charge=true // Firmware mode has no direct charge-gate command.
                } else { try hardware(decision) }
            }
            try encode(config, path: configurationPath)
            try encode(ServiceState(configuration: config, battery: battery, message: decision.message,
                                    chargeCommand: capabilities & 4 != 0 || config.adapterFallback == true ? nil : decision.charge, dischargeCommand: decision.discharge,
                                    capabilities: Int(cm_capabilities())), path: statePath)
        } catch {
            let original = error.localizedDescription
            config.mode = .system
            var restoreError: String? = nil
            if config.ownsHardware {
                do { try restoreManaged(config) } catch { restoreError = error.localizedDescription }
            }
            config.ownsHardware = restoreError != nil
            if restoreError == nil { config.firmwareOriginal=nil;config.adapterFallback=nil }
            try encode(config, path: configurationPath)
            let message = restoreError == nil ? "控制失败，已恢复系统管理" : "控制和恢复失败，请立即拔插电源并检查"
            try encode(ServiceState(configuration: config, battery: try? Battery.read(), message: message,
                                    error: original + (restoreError.map { "; restore: " + $0 } ?? "")), path: statePath)
            throw CMError.message(message + ": " + original)
        }
    }
}
