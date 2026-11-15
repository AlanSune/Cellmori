// SPDX-License-Identifier: MIT
import Foundation
import Darwin

struct SleepHoldSnapshot: Codable, Equatable {
    let originallyDisabled: Bool
    let started: Date
}

// Persist intent BEFORE changing the global flag. Keep the record until restore
// is confirmed, including write failures or a process crash between operations.
struct SleepHoldController {
    var load: () throws -> SleepHoldSnapshot?
    var save: (SleepHoldSnapshot) throws -> Void
    var remove: () throws -> Void
    var read: () throws -> Bool
    var write: (Bool) throws -> Void

    func acquire() throws -> Bool {
        let current = try read()
        if try load() == nil {
            try save(SleepHoldSnapshot(originallyDisabled: current, started: Date()))
        }
        if !current { try write(true) }
        guard try read() else { throw CMError.message("系统未确认保持唤醒，主动放电没有启动") }
        return true
    }
    func release() throws {
        guard let original = try load() else { return }
        if !original.originallyDisabled {
            if try read() { try write(false) }
            guard try !read() else { throw CMError.message("恢复系统睡眠未确认，后台将重试") }
        }
        // Do not re-disable sleep if someone enabled it after an originally-disabled
        // snapshot. Restore only the flag that this controller actually enabled.
        try remove()
    }
}

enum SystemSleepControl {
    // Fixed executable and finite arguments; never execute a shell or accept a path.
    private static func command(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            usleep(50_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw CMError.message("系统睡眠控制超时，未确认保持唤醒")
        }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw CMError.message("系统睡眠控制失败：" + output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return output
    }
    static func parseDisabled(_ output: String) throws -> Bool {
        let matches = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let parts = line.split(whereSeparator: \.isWhitespace)
            return parts.count == 2 && parts[0] == "SleepDisabled" ? String(parts[1]) : nil
        }
        guard matches.count == 1, matches[0] == "0" || matches[0] == "1" else {
            throw CMError.message("无法读取原系统睡眠设置，未启用保持唤醒")
        }
        return matches[0] == "1"
    }
    static func read() throws -> Bool { try parseDisabled(command(["-g"])) }
    static func write(_ disabled: Bool) throws {
        guard geteuid() == 0 else { throw CMError.message("睡眠控制需要后台服务权限") }
        _ = try command(["-a", "disablesleep", disabled ? "1" : "0"])
    }
}
