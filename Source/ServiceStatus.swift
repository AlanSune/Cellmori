// SPDX-License-Identifier: MIT
import Foundation

enum ServiceCondition: String {
    case checking, missing, incomplete, stopped, starting, stale, running, updateAvailable, failed
    var title: String {
        switch self {
        case .checking: return "正在检查"
        case .missing: return "未安装"
        case .incomplete: return "安装不完整"
        case .stopped: return "已安装 · 未运行"
        case .starting: return "正在启动"
        case .stale: return "运行中 · 无响应"
        case .running: return "已安装 · 运行正常"
        case .updateAvailable: return "运行正常 · 可更新"
        case .failed: return "无法确认状态"
        }
    }
}
struct ServiceInspection {
    var condition: ServiceCondition = .checking
    var binaryExists = false
    var plistExists = false
    var registered = false
    var processRunning = false
    var pid: Int?
    var checkedAt = Date()
    var state: ServiceState?
    var detail = "正在核对安装文件、launchd 进程与后台响应。"
    var healthy: Bool { [.running, .updateAvailable].contains(condition) }
    static func classify(binary: Bool, plist: Bool, registered: Bool, running: Bool, pid: Int?, state: ServiceState?, now: Date, permissionDenied: Bool = false) -> ServiceInspection {
        var result = ServiceInspection(binaryExists: binary, plistExists: plist, registered: registered, processRunning: running, pid: pid, checkedAt: now, state: state)
        if !binary && !plist && !registered {
            result.condition = .missing; result.detail = "尚未安装后台服务。安装后可在关闭界面时继续维护充电策略。"
        } else if !binary || !plist {
            result.condition = .incomplete; result.detail = "后台程序或启动配置缺失，建议修复安装。"
        } else if permissionDenied {
            result.condition = .failed; result.detail = "系统拒绝读取 launchd 状态，无法确认后台进程；不会仅凭文件存在判定安装成功。"
        } else if !registered || !running || pid == nil {
            result.condition = .stopped; result.detail = "安装文件存在，但 launchd 没有正在运行的服务进程。请修复服务。"
        } else if let state {
            let age = now.timeIntervalSince(state.updated)
            if age < -10 || age > 65 {
                result.condition = .stale; result.detail = "进程存在，但最近 65 秒内没有有效响应。请重新检查或修复服务。"
            } else if let name = state.serviceName, name != serviceIdentifier {
                result.condition = .failed; result.detail = "响应中的服务名称不匹配，未认定为正常服务。"
            } else if let reportedPID = state.daemonPID, reportedPID != pid {
                result.condition = .starting; result.detail = "正在等待当前进程的首次响应，避免将旧进程的状态当作安装成功。"
            } else {
                result.condition = state.helperVersion == expectedHelperVersion ? .running : .updateAvailable
                result.detail = state.helperVersion == expectedHelperVersion ? "安装文件、launchd 运行进程和最新响应均已确认。" : "后台正在响应，但版本与应用所需版本不同；请更新以启用最新修复。"
            }
        } else {
            result.condition = .starting; result.detail = "服务进程已启动，正在等待首次响应。"
        }
        return result
    }
    static func read() -> ServiceInspection {
        let fm = FileManager.default
        let binary = fm.isExecutableFile(atPath: helperPath)
        let plist = fm.fileExists(atPath: "/Library/LaunchDaemons/" + serviceIdentifier + ".plist")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/" + serviceIdentifier]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            let text = String(data: data, encoding: .utf8) ?? ""
            let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            let pid = lines.first { $0.hasPrefix("pid = ") }.flatMap { Int($0.dropFirst(6)) }
            let state = try? decode(ServiceState.self, path: statePath)
            return classify(binary: binary, plist: plist, registered: process.terminationStatus == 0,
                            running: lines.contains("state = running"), pid: pid, state: state, now: Date(),
                            permissionDenied: text.localizedCaseInsensitiveContains("not permitted") || text.localizedCaseInsensitiveContains("permission denied"))
        } catch {
            var result = ServiceInspection(binaryExists: binary, plistExists: plist)
            result.condition = .failed; result.detail = "无法读取系统服务状态：" + error.localizedDescription
            return result
        }
    }
}
