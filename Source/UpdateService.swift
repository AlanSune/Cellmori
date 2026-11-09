// SPDX-License-Identifier: MIT
import Foundation
import CryptoKit

struct AppReleaseVersion: Comparable, Equatable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var values: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part.count == 1 || part.first != "0", let value = Int(part) else { return nil }
            values.append(value)
        }
        major = values[0]; minor = values[1]; patch = values[2]
    }
    var description: String { "\(major).\(minor).\(patch)" }
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

struct ReleaseAsset: Decodable {
    var name: String
    var browser_download_url: URL
    var size: Int64
    var digest: String?
}
struct AppRelease: Decodable {
    var tag_name: String
    var html_url: URL
    var name: String?
    var body: String?
    var draft: Bool
    var prerelease: Bool
    var assets: [ReleaseAsset]
}
struct AppUpdate: Identifiable {
    let version: AppReleaseVersion
    let releaseURL: URL
    let notes: String
    let package: ReleaseAsset
    let checksum: ReleaseAsset
    var id: String { version.description }
}
struct VerifiedUpdate {
    let update: AppUpdate
    let file: URL
    let sha256: String
}

enum UpdateValidation {
    static let repository = "https://github.com/AlanSune/Cellmori"
    static let endpoint = URL(string: "https://api.github.com/repos/AlanSune/Cellmori/releases/latest")!
    static let maximumPackageSize: Int64 = 200 * 1024 * 1024
    static func candidate(_ release: AppRelease, current: String) throws -> AppUpdate? {
        guard !release.draft && !release.prerelease else { return nil }
        guard let version = AppReleaseVersion(release.tag_name), let current = AppReleaseVersion(current) else {
            throw CMError.message("更新版本格式无法识别，请到 GitHub 发布页核对。")
        }
        guard version > current else { return nil }
        guard release.html_url.absoluteString == repository + "/releases/tag/" + release.tag_name else {
            throw CMError.message("更新来源与 Cellmori 仓库不匹配，已停止更新。")
        }
        let name = "Cellmori-\(version)-arm64.pkg"
        let packages = release.assets.filter { $0.name == name }
        let checksums = release.assets.filter { $0.name == name + ".sha256" }
        guard packages.count == 1, checksums.count == 1,
              let package = packages.first, let checksum = checksums.first,
              package.size > 0, package.size <= maximumPackageSize,
              checksum.size > 0, checksum.size <= 16 * 1024 else {
            throw CMError.message("此版本缺少适用的 Apple Silicon 安装包或校验文件，请到发布页查看。")
        }
        for asset in [package, checksum] {
            let expected = repository + "/releases/download/" + release.tag_name + "/" + asset.name
            guard asset.browser_download_url.absoluteString == expected else {
                throw CMError.message("安装资源不属于指定发布版本，已停止下载。")
            }
        }
        return AppUpdate(version: version, releaseURL: release.html_url,
                         notes: String((release.body ?? "此版本未提供更新说明。").prefix(20_000)), package: package, checksum: checksum)
    }
    static func expectedHash(_ data: Data, name: String) throws -> String {
        guard data.count <= 16 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw CMError.message("更新校验文件无法读取。")
        }
        let records = text.split(whereSeparator: \.isNewline).compactMap { line -> (String, String)? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { return nil }
            let hash = String(fields[0]).lowercased()
            let filename = fields[1].hasPrefix("*") ? String(fields[1].dropFirst()) : String(fields[1])
            guard hash.count == 64, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
            return (hash, filename)
        }.filter { $0.1 == name }
        guard records.count == 1 else { throw CMError.message("校验文件未唯一指定此安装包，已停止更新。") }
        return records[0].0
    }
    static func allowsRedirect(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil, url.port == nil else { return false }
        return ["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(url.host ?? "")
    }
    static func fileHash(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func verify(_ file: URL, expectedSize: Int64, hash: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == expectedSize,
              try fileHash(file) == hash else {
            throw CMError.message("安装包大小或 SHA-256 校验不匹配，已阻止安装。请重新下载。")
        }
    }
}

private final class UpdateTransferDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let maximumBytes: Int64
    let progress: @Sendable (Double) -> Void
    init(maximumBytes: Int64, progress: @escaping @Sendable (Double) -> Void = { _ in }) {
        self.maximumBytes = maximumBytes; self.progress = progress
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(UpdateValidation.allowsRedirect(request.url) ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximumBytes { downloadTask.cancel(); return }
        progress(min(1, Double(totalBytesWritten) / Double(max(1, maximumBytes))))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

struct UpdateService {
    private let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration = .ephemeral) { self.configuration = configuration }
    private func session() -> URLSession {
        let configuration = self.configuration.copy() as! URLSessionConfiguration
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }
    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Cellmori/\(appVersion)", forHTTPHeaderField: "User-Agent")
        return request
    }
    func latest() async throws -> AppUpdate? {
        let session = session(); defer { session.invalidateAndCancel() }
        var request = request(UpdateValidation.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request, delegate: UpdateTransferDelegate(maximumBytes: 1024 * 1024))
        guard let http = response as? HTTPURLResponse else { throw CMError.message("GitHub 更新服务没有返回有效响应。") }
        if http.statusCode == 404 { return nil }
        if http.statusCode == 403 || http.statusCode == 429 { throw CMError.message("GitHub 暂时限制了更新请求，请稍后重试。") }
        guard http.statusCode == 200, data.count <= 1024 * 1024 else { throw CMError.message("检查更新失败，请稍后重试。") }
        let release = try JSONDecoder().decode(AppRelease.self, from: data)
        return try UpdateValidation.candidate(release, current: appVersion)
    }
    func download(_ update: AppUpdate, progress: @escaping @Sendable (Double) -> Void) async throws -> VerifiedUpdate {
        let session = session(); defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request(update.checksum.browser_download_url), delegate: UpdateTransferDelegate(maximumBytes: 16 * 1024))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CMError.message("无法下载 SHA-256 校验文件。") }
        let hash = try UpdateValidation.expectedHash(data, name: update.package.name)
        if let digest = update.package.digest, digest.lowercased() != "sha256:" + hash {
            throw CMError.message("发布资源的校验信息互相矛盾，已停止更新。")
        }
        try Task.checkCancellation()
        let delegate = UpdateTransferDelegate(maximumBytes: update.package.size, progress: progress)
        let (temporary, packageResponse) = try await session.download(for: request(update.package.browser_download_url), delegate: delegate)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (packageResponse as? HTTPURLResponse)?.statusCode == 200 else { throw CMError.message("安装包下载失败，请稍后重试。") }
        try Task.checkCancellation()
        try UpdateValidation.verify(temporary, expectedSize: update.package.size, hash: hash)
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.cellmori.app/Updates", isDirectory: true)
        let folder = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = folder.appendingPathComponent(update.package.name)
        do { try FileManager.default.moveItem(at: temporary, to: destination) }
        catch { try? FileManager.default.removeItem(at: folder); throw error }
        return VerifiedUpdate(update: update, file: destination, sha256: hash)
    }
}
