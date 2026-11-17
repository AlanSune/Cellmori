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
    // Never pump the daemon's run loop while its policy lock is held.
    // Foundation Process.waitUntilExit can dispatch a timer that reacquires it.
    static func output(executable: String, arguments: [String], timeout: TimeInterval = 3) throws -> String {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw CMError.message("无法建立睡眠控制通道") }
        defer { close(descriptors[0]) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, descriptors[0])
        posix_spawn_file_actions_addclose(&actions, descriptors[1])
        let strings = ([executable] + arguments).map { strdup($0) }
        defer { for string in strings { free(string) } }
        var argv = strings + [nil]
        var pid: pid_t = 0
        let spawn = posix_spawn(&pid, executable, &actions, nil, &argv, environ)
        close(descriptors[1])
        guard spawn == 0 else { throw CMError.message("无法启动睡眠控制：\(spawn)") }
        var reaped = false
        defer {
            if !reaped {
                kill(pid, SIGKILL)
                let child = pid
                DispatchQueue.global().async { var status: Int32 = 0; _ = waitpid(child, &status, 0) }
            }
        }
        guard fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0 else { throw CMError.message("无法读取睡眠控制结果") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var status: Int32 = 0
        while true {
            while true {
                let count = Darwin.read(descriptors[0], &buffer, buffer.count)
                if count > 0 {
                    data.append(contentsOf: buffer.prefix(count))
                    guard data.count <= 65536 else { throw CMError.message("睡眠控制输出异常") }
                } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK { break }
                else if errno != EINTR { throw CMError.message("读取睡眠控制结果失败") }
            }
            if !reaped {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid { reaped = true; continue } // Drain remaining output once more.
                if result < 0 && errno != EINTR { throw CMError.message("无法确认睡眠控制结果") }
            } else { break }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw CMError.message("系统睡眠控制超时，未确认保持唤醒")
            }
            usleep(10_000)
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard status == 0 else { throw CMError.message("系统睡眠控制失败：" + text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return text
    }
    private static func command(_ arguments: [String]) throws -> String {
        try output(executable: "/usr/bin/pmset", arguments: arguments)
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
