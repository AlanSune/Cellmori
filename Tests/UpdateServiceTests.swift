// SPDX-License-Identifier: MIT
import Foundation

private final class MockReleaseProtocol: URLProtocol {
    static var responseCode = 200
    static var responseData = Data()
    static var failure: URLError?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let failure = Self.failure { client?.urlProtocol(self, didFailWithError: failure); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.responseCode, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class MemoryUpdatePreferences: UserDefaults {
    var values: [String: Any] = [:]
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

@main struct UpdateServiceTests {
    static var checks = 0
    static func check(_ value: Bool, _ description: String) {
        precondition(value, description); checks += 1
    }
    static func rejects(_ description: String, _ operation: () throws -> Void) {
        do { try operation(); preconditionFailure(description) } catch { checks += 1 }
    }
    static func release() -> AppRelease {
        let url = "https://github.com/AlanSune/Cellmori"
        return AppRelease(tag_name: "v0.6.3", html_url: URL(string: url + "/releases/tag/v0.6.3")!, body: "Release notes", draft: false, prerelease: false, assets: [
            ReleaseAsset(name: "Cellmori-0.6.3-arm64.pkg", browser_download_url: URL(string: url + "/releases/download/v0.6.3/Cellmori-0.6.3-arm64.pkg")!, size: 3),
            ReleaseAsset(name: "Cellmori-0.6.3-arm64.pkg.sha256", browser_download_url: URL(string: url + "/releases/download/v0.6.3/Cellmori-0.6.3-arm64.pkg.sha256")!, size: 97)
        ])
    }
    @MainActor static func main() async throws {
        check(AppReleaseVersion("v0.6.2") == AppReleaseVersion("0.6.2"), "optional v prefix")
        check(AppReleaseVersion("0.10.0")! > AppReleaseVersion("0.9.9")!, "numeric version ordering")
        for invalid in ["1.2", "1.2.3-beta", "01.2.3", "1.-2.3", "1.2.3/other", "1.2.999999999999999999999999999999999"] {
            check(AppReleaseVersion(invalid) == nil, "invalid stable version")
        }
        let valid = release()
        check(try UpdateValidation.candidate(valid, current: appVersion) != nil, "newer release accepted")
        check(try UpdateValidation.candidate(valid, current: "0.6.3") == nil, "same version ignored")
        check(try UpdateValidation.candidate(valid, current: "0.7.0") == nil, "downgrade ignored")
        var changed = valid; changed.prerelease = true
        check(try UpdateValidation.candidate(changed, current: appVersion) == nil, "prerelease ignored")
        changed = valid; changed.draft = true
        check(try UpdateValidation.candidate(changed, current: appVersion) == nil, "draft ignored")
        changed = valid; changed.html_url = URL(string: "https://example.com/release")!
        rejects("wrong repository") { _ = try UpdateValidation.candidate(changed, current: appVersion) }
        changed = valid; changed.assets[0].browser_download_url = URL(string: "https://github.com/other/project/package.pkg")!
        rejects("wrong asset location") { _ = try UpdateValidation.candidate(changed, current: appVersion) }
        changed = valid; changed.assets.removeLast()
        rejects("missing checksum") { _ = try UpdateValidation.candidate(changed, current: appVersion) }
        changed = valid; changed.assets.append(changed.assets[0])
        rejects("ambiguous package") { _ = try UpdateValidation.candidate(changed, current: appVersion) }
        changed = valid; changed.assets[0].size = UpdateValidation.maximumPackageSize + 1
        rejects("oversized package") { _ = try UpdateValidation.candidate(changed, current: appVersion) }
        let hash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let name = valid.assets[0].name
        let record = Data((hash + "  " + name + "\n").utf8)
        check(try UpdateValidation.expectedHash(record, name: name) == hash, "checksum format")
        check(try UpdateValidation.expectedHash(Data((hash.uppercased() + " *" + name).utf8), name: name) == hash, "binary checksum format")
        rejects("duplicate checksum") { _ = try UpdateValidation.expectedHash(record + record, name: name) }
        rejects("wrong checksum filename") { _ = try UpdateValidation.expectedHash(record, name: "another.pkg") }
        rejects("invalid hash") { _ = try UpdateValidation.expectedHash(Data(("xyz  " + name).utf8), name: name) }
        check(UpdateValidation.allowsRedirect(URL(string: "https://release-assets.githubusercontent.com/file?download=1")), "GitHub CDN allowed")
        for bad in ["http://github.com/file", "https://github.com.evil.test/file", "https://user:password@github.com/file", "https://example.com/file", "https://github.com:8443/file"] {
            check(!UpdateValidation.allowsRedirect(URL(string: bad)), "unexpected redirect rejected")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("test.pkg")
        try Data("abc".utf8).write(to: file)
        check(try UpdateValidation.fileHash(file) == hash, "known SHA-256 vector")
        try UpdateValidation.verify(file, expectedSize: 3, hash: hash); checks += 1
        rejects("length mismatch") { try UpdateValidation.verify(file, expectedSize: 4, hash: hash) }
        try Data("abd".utf8).write(to: file)
        rejects("tampered package") { try UpdateValidation.verify(file, expectedSize: 3, hash: hash) }
        try Data("abc".utf8).write(to: file)
        let link = directory.appendingPathComponent("link.pkg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        rejects("symbolic link cannot be installed") { try UpdateValidation.verify(link, expectedSize: 3, hash: hash) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockReleaseProtocol.self]
        let service = UpdateService(configuration: configuration)
        MockReleaseProtocol.responseCode = 404
        check(try await service.latest() == nil, "no official release is not a false update")
        MockReleaseProtocol.responseCode = 403
        do { _ = try await service.latest(); preconditionFailure("rate limit accepted") } catch { checks += 1 }
        MockReleaseProtocol.responseCode = 200
        MockReleaseProtocol.responseData = Data("not json".utf8)
        do { _ = try await service.latest(); preconditionFailure("invalid JSON accepted") } catch { checks += 1 }
        MockReleaseProtocol.failure = URLError(.notConnectedToInternet)
        do { _ = try await service.latest(); preconditionFailure("offline request accepted") } catch { checks += 1 }
        MockReleaseProtocol.failure = nil
        MockReleaseProtocol.responseData = try JSONSerialization.data(withJSONObject: [
            "tag_name":"v0.6.3", "html_url":"https://github.com/AlanSune/Cellmori/releases/tag/v0.6.3",
            "body":"Notes", "draft":false, "prerelease":false,
            "assets": valid.assets.map { ["name":$0.name,"browser_download_url":$0.browser_download_url.absoluteString,"size":$0.size] as [String:Any] }
        ])
        let found = try await service.latest()
        check(found?.version.description == "0.6.3", "HTTP release parsing and selection")
        let preferences = MemoryUpdatePreferences(suiteName: "CellmoriUpdatePreferencesTests")!
        let fresh = AppUpdater(preferences: preferences)
        check(fresh.automaticallyCheck, "automatic checks enabled on first use")
        fresh.automaticallyCheck = false
        let restored = AppUpdater(preferences: preferences)
        check(!restored.automaticallyCheck, "explicit user opt-out preserved")
        restored.checkAutomaticallyIfDue()
        check(!restored.checking, "disabled checks do not start a request")
        print("PASS: \(checks) update selection, origin, checksum, tampering and mock HTTP checks; no network or installation")
    }
}
