// SPDX-License-Identifier: MIT
import Foundation
import Darwin
import SystemConfiguration

let controlServiceName = "io.cellmori.helper.control"
let controlIdentityPath = serviceDirectory + "/client-identity.plist"

@objc protocol CellmoriControl {
    func perform(_ arguments: [String], reply: @escaping (Int32, String) -> Void)
}

struct ControlIdentity: Codable {
    let clientHash: String
    let helperHash: String
    let userID: UInt32
    static func validHash(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy { $0.isHexDigit && $0.isASCII }
    }
    static func read() throws -> ControlIdentity {
        for path in [serviceDirectory, controlIdentityPath] {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_uid == 0, info.st_mode & 0o022 == 0,
                  info.st_mode & S_IFMT == (path == serviceDirectory ? S_IFDIR : S_IFREG) else {
                throw CMError.message("后台通信身份文件缺失或权限异常，请更新后台服务。")
            }
        }
        let identity = try PropertyListDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: controlIdentityPath)))
        guard validHash(identity.clientHash), validHash(identity.helperHash), identity.userID >= 501 else {
            throw CMError.message("后台通信身份无效，请重新安装后台服务。")
        }
        return identity
    }
    static func requirement(hash: String) -> String { "cdhash H\"\(hash)\"" }
}

// Exact, finite command surface; no shell strings, executable paths or file paths.
func permittedControlRequest(_ args: [String]) -> Bool {
    if args == ["ping"] || args == ["reset"] || args == ["firmware-test"] { return true }
    guard args.count == 5, args[0] == "configure", let _ = Mode(rawValue: args[1]),
          let target = Int(args[2]), (40...100).contains(target),
          let temperature = Double(args[3]), temperature.isFinite, (35...42).contains(temperature),
          let discharge = Int(args[4]), (20...90).contains(discharge) else { return false }
    return true
}

final class ControlServer: NSObject, NSXPCListenerDelegate, CellmoriControl {
    private let identity: ControlIdentity
    private let listener: NSXPCListener
    private let execute: ([String]) throws -> String
    init(execute: @escaping ([String]) throws -> String) throws {
        identity = try ControlIdentity.read()
        self.execute = execute
        listener = NSXPCListener(machServiceName: controlServiceName)
        super.init()
        listener.setConnectionCodeSigningRequirement(ControlIdentity.requirement(hash: identity.clientHash))
        listener.delegate = self
        listener.resume()
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        var consoleUID: uid_t = 0
        _ = SCDynamicStoreCopyConsoleUser(nil, &consoleUID, nil)
        guard consoleUID == identity.userID, connection.effectiveUserIdentifier == identity.userID else { return false }
        connection.setCodeSigningRequirement(ControlIdentity.requirement(hash: identity.clientHash))
        connection.exportedInterface = NSXPCInterface(with: CellmoriControl.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
    func perform(_ arguments: [String], reply: @escaping (Int32, String) -> Void) {
        // Recheck console ownership on each request, including an existing connection.
        var consoleUID: uid_t = 0
        _ = SCDynamicStoreCopyConsoleUser(nil, &consoleUID, nil)
        guard consoleUID == identity.userID, permittedControlRequest(arguments) else {
            reply(1, "拒绝未授权的后台请求。"); return
        }
        DispatchQueue.main.async {
            var activeUID: uid_t = 0
            _ = SCDynamicStoreCopyConsoleUser(nil, &activeUID, nil)
            guard activeUID == self.identity.userID else { reply(1, "登录账户已切换，操作已取消。"); return }
            do { reply(0, try self.execute(arguments)) }
            catch { reply(1, error.localizedDescription) }
        }
    }
}

// One completion even if timeout, interruption and reply race. Never auto-retry a write.
private final class PendingControl: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    let connection: NSXPCConnection
    let completion: (Int32, String) -> Void
    init(connection: NSXPCConnection, completion: @escaping (Int32, String) -> Void) {
        self.connection = connection; self.completion = completion
    }
    func finish(_ code: Int32, _ text: String) {
        lock.lock()
        if completed { lock.unlock(); return }
        completed = true; lock.unlock()
        connection.invalidate()
        completion(code, text)
    }
}
enum ControlClient {
    static func request(_ arguments: [String]) async -> (Int32, String) {
        do {
            guard permittedControlRequest(arguments) else { throw CMError.message("不支持的控制请求") }
            let identity = try ControlIdentity.read()
            guard identity.userID == getuid() else { throw CMError.message("当前账户未获后台授权，请重新安装后台服务。") }
            return await withCheckedContinuation { continuation in
                let connection = NSXPCConnection(machServiceName: controlServiceName, options: .privileged)
                connection.setCodeSigningRequirement(ControlIdentity.requirement(hash: identity.helperHash))
                connection.remoteObjectInterface = NSXPCInterface(with: CellmoriControl.self)
                let pending = PendingControl(connection: connection) { continuation.resume(returning: ($0, $1)) }
                connection.invalidationHandler = { [weak pending] in pending?.finish(1, "后台连接已中断，请检查服务版本与应用身份。") }
                connection.interruptionHandler = { [weak pending] in pending?.finish(1, "后台重启或连接中断；请检查状态后再操作。") }
                connection.resume()
                let proxy = connection.remoteObjectProxyWithErrorHandler { pending.finish(1, "无法连接后台：" + $0.localizedDescription) } as? CellmoriControl
                guard let proxy else { pending.finish(1, "后台通信接口不可用"); return }
                proxy.perform(arguments) { pending.finish($0, $1) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                    pending.finish(1, "后台请求超时，结果尚未确认；请先检查当前状态，避免重复提交。")
                }
            }
        } catch { return (1, error.localizedDescription) }
    }
}
