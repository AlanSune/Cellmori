// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

@MainActor final class AppUpdater: ObservableObject {
    @Published private(set) var available: AppUpdate?
    @Published private(set) var downloaded: VerifiedUpdate?
    @Published private(set) var checking = false
    @Published private(set) var downloading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var status = "仅检查 GitHub 正式版，不接收预发布版本。"
    @Published private(set) var lastChecked: Date?
    @Published var automaticallyCheck: Bool {
        didSet {
            guard !preview else { return }
            preferences.set(automaticallyCheck, forKey: "automaticallyCheckUpdates")
            if automaticallyCheck { checkAutomaticallyIfDue() }
        }
    }
    var onError: ((String) -> Void)?
    private let preferences: UserDefaults
    private let preview: Bool
    private let service = UpdateService()
    private var downloadTask: Task<Void, Never>?
    var busy: Bool { checking || downloading }
    init(preview: Bool = false, preferences: UserDefaults = .standard) {
        self.preview = preview
        self.preferences = preferences
        automaticallyCheck = preview ? false : (preferences.object(forKey: "automaticallyCheckUpdates") as? Bool ?? true)
        if !preview { lastChecked = preferences.object(forKey: "lastUpdateCheck") as? Date }
    }
    func checkAutomaticallyIfDue() {
        guard !preview, automaticallyCheck else { return }
        let previous = preferences.object(forKey: "lastAutomaticUpdateAttempt") as? Date ?? .distantPast
        guard Date().timeIntervalSince(previous) >= 24 * 3600 else { return }
        check(automatic: true)
    }
    func check(automatic: Bool = false, showErrorAlert: Bool = true) {
        guard !preview, !busy else { return }
        checking = true; status = "正在检查 GitHub 正式版…"
        if automatic { preferences.set(Date(), forKey: "lastAutomaticUpdateAttempt") }
        Task {
            defer { checking = false }
            do {
                available = try await service.latest()
                downloaded = nil
                lastChecked = Date()
                preferences.set(lastChecked, forKey: "lastUpdateCheck")
                status = available.map { "发现新版本 \($0.version)" } ?? "目前没有比 \(appVersion) 更新的正式版本。"
            } catch {
                status = "检查未完成，可稍后重试。"
                if !automatic && showErrorAlert { onError?(error.localizedDescription) }
            }
        }
    }
    func download() {
        guard !preview, !busy, let update = available else { return }
        downloading = true; progress = 0; status = "正在下载 \(update.version)…"
        downloadTask = Task {
            defer { downloading = false; downloadTask = nil }
            do {
                let result = try await service.download(update) { [weak self] progress in
                    Task { @MainActor in self?.progress = progress }
                }
                try Task.checkCancellation()
                downloaded = result; progress = 1
                status = "下载完成，SHA-256 校验通过。"
            } catch is CancellationError { status = "已取消下载。" }
            catch let error as URLError where error.code == .cancelled { status = "下载已取消或被安全检查终止，可重试。" }
            catch { status = "下载未完成，未启动安装。"; onError?(error.localizedDescription) }
        }
    }
    func cancelDownload() { downloadTask?.cancel() }
    func install() {
        guard !preview, !busy, let downloaded else { return }
        do {
            // Recheck immediately before handing the file to Installer.
            try UpdateValidation.verify(downloaded.file, expectedSize: downloaded.update.package.size, hash: downloaded.sha256)
            guard NSWorkspace.shared.open(downloaded.file) else { throw CMError.message("无法打开系统安装器，请在 Finder 中打开安装包。") }
            NSApp.terminate(nil)
        } catch { onError?(error.localizedDescription) }
    }
    func revealDownload() {
        guard let downloaded else { return }
        NSWorkspace.shared.activateFileViewerSelecting([downloaded.file])
    }
}

struct AppUpdateView: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("当前版本 \(appVersion)", systemImage: "arrow.down.circle")
                Spacer()
                Button(updater.checking ? "检查中…" : "检查更新") { updater.check() }.disabled(updater.busy)
            }
            HStack {
                Text("自动检查正式版（每天最多一次）")
                Spacer()
                Toggle("自动检查正式版", isOn: $updater.automaticallyCheck)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Text("默认开启，可随时关闭。启动时每天最多检查一次；只连接 GitHub，不上传电池数据。")
                .font(.caption).foregroundStyle(.secondary)
            Text(updater.status).font(.callout)
            if let last = updater.lastChecked {
                Text("上次检查：\(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let update = updater.available {
                Divider()
                HStack {
                    Text("Cellmori \(update.version)").font(.headline)
                    Spacer()
                    Link("发布详情", destination: update.releaseURL)
                }
                ScrollView { Text(update.notes).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 140)
                if updater.downloading {
                    HStack {
                        ProgressView(value: updater.progress)
                        Text(updater.progress.formatted(.percent.precision(.fractionLength(0))))
                            .font(.callout).monospacedDigit().frame(width: 42, alignment: .trailing)
                    }
                    Button("取消下载") { updater.cancelDownload() }
                } else if updater.downloaded != nil {
                    HStack {
                        Button("安装更新并退出") { updater.install() }.buttonStyle(.borderedProminent)
                        Button("在 Finder 中显示") { updater.revealDownload() }
                    }
                } else {
                    Button("下载更新") { updater.download() }.buttonStyle(.borderedProminent).disabled(updater.busy)
                }
            }
            DisclosureGroup("安装与验证说明") {
                Text("下载后核对 SHA-256，安装前再次校验。安装由 macOS 请求管理员授权，后台继续维护当前策略。系统可能要求确认安装包来源，应用不会跳过系统安全检查。")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }.font(.caption)
            Link("打开 GitHub 发布页", destination: URL(string: UpdateValidation.repository + "/releases")!)
                .font(.caption)
        }
    }
}

struct MenuUpdateControls<Actions: View, Exit: View>: View {
    @ObservedObject var updater: AppUpdater
    @State private var checkedFromMenu = false
    let openDetails: () -> Void
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var exit: () -> Exit

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                actions()
                Spacer()
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
                        Label("检查更新", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(updater.busy)
                Spacer()
                exit()
            }
            if let update = updater.available {
                Button(action: openDetails) {
                    Label("查看新版 \(update.version)", systemImage: "arrow.down.circle")
                }
            }
            if checkedFromMenu && !updater.busy {
                Text(updater.status).foregroundStyle(.secondary)
            }
        }.font(.caption).buttonStyle(.borderless)
    }
}
