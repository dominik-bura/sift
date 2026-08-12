import AppKit
import CryptoKit
import Foundation
import Security

struct UpdateRelease: Equatable, Sendable {
    let version: String
    let downloadURL: URL
    let checksumURL: URL?
    let digest: String?
    let releasePageURL: URL
}

enum UpdateState: Equatable, Sendable {
    case unavailable
    case idle
    case checking
    case upToDate(Date)
    case available(UpdateRelease)
    case downloading(UpdateRelease)
    case failed(String)
}

struct UpdateService: Sendable {
    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    var currentVersion: String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var buildNumber: String {
        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    var repository: String? {
        guard let value = bundle.object(forInfoDictionaryKey: "SiftUpdateRepository") as? String,
              Self.isValidRepository(value) else { return nil }
        return value
    }

    func checkForUpdate() async throws -> UpdateRelease? {
        guard let repository,
              let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw UpdateError.notConfigured
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Sift/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session().data(for: request)
        try Self.validate(response: response, allowedHosts: ["api.github.com"])
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let version = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard Self.compareVersions(version, currentVersion) == .orderedDescending else { return nil }
        guard let archive = release.assets.first(where: { $0.name.hasPrefix("Sift-") && $0.name.hasSuffix(".zip") }),
              Self.isAllowedDownloadURL(archive.browserDownloadURL),
              archive.browserDownloadURL.path.hasPrefix("/\(repository)/releases/download/"),
              Self.isAllowedReleaseURL(release.htmlURL),
              release.htmlURL.path.hasPrefix("/\(repository)/releases/tag/") else {
            throw UpdateError.invalidRelease
        }
        let checksum = release.assets.first(where: { $0.name == archive.name + ".sha256" })?.browserDownloadURL
        if let checksum, !Self.isAllowedDownloadURL(checksum) { throw UpdateError.invalidRelease }
        guard archive.digest?.hasPrefix("sha256:") == true || checksum != nil else {
            throw UpdateError.missingChecksum
        }
        return UpdateRelease(
            version: version,
            downloadURL: archive.browserDownloadURL,
            checksumURL: checksum,
            digest: archive.digest,
            releasePageURL: release.htmlURL
        )
    }

    func downloadAndStage(_ release: UpdateRelease) async throws -> URL {
        let expectedDigest = try await expectedDigest(for: release)
        let (downloadedURL, response) = try await session().download(from: release.downloadURL)
        try Self.validate(
            response: response,
            allowedHosts: ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"]
        )
        let actualDigest = try Self.sha256(of: downloadedURL)
        guard actualDigest.caseInsensitiveCompare(expectedDigest) == .orderedSame else {
            throw UpdateError.checksumMismatch
        }

        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiftUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let archiveURL = stagingRoot.appendingPathComponent("Sift.zip")
        try FileManager.default.moveItem(at: downloadedURL, to: archiveURL)
        let result = SecureCommandRunner().run(
            URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", archiveURL.path, stagingRoot.path],
            timeout: 60
        )
        guard result.exitCode == 0 else { throw UpdateError.invalidArchive }
        let appURL = stagingRoot.appendingPathComponent("Sift.app", isDirectory: true)
        let resolvedApp = appURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedApp.path.hasPrefix(stagingRoot.standardizedFileURL.path + "/") else {
            throw UpdateError.invalidApplication
        }
        try validateApplication(at: appURL, expectedVersion: release.version)
        return appURL
    }

    @MainActor
    func launchInstaller(for stagedApp: URL) throws {
        let currentApp = bundle.bundleURL.standardizedFileURL
        guard currentApp.pathExtension == "app", currentApp.lastPathComponent == "Sift.app" else {
            throw UpdateError.notRunningFromApplication
        }
        guard FileManager.default.isWritableFile(atPath: currentApp.deletingLastPathComponent().path) else {
            throw UpdateError.installLocationNotWritable
        }
        let helper = currentApp.appendingPathComponent("Contents/Helpers/SiftUpdater")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw UpdateError.missingInstaller }
        let process = Process()
        process.executableURL = helper
        process.arguments = [currentApp.path, stagedApp.path, String(ProcessInfo.processInfo.processIdentifier)]
        try process.run()
        NSApplication.shared.terminate(nil)
    }

    private func expectedDigest(for release: UpdateRelease) async throws -> String {
        if let digest = release.digest, digest.hasPrefix("sha256:") {
            return String(digest.dropFirst("sha256:".count))
        }
        guard let checksumURL = release.checksumURL else { throw UpdateError.missingChecksum }
        let (data, response) = try await session().data(from: checksumURL)
        try Self.validate(
            response: response,
            allowedHosts: ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"]
        )
        let checksum = String(decoding: data, as: UTF8.self).split(whereSeparator: \Character.isWhitespace).first.map(String.init)
        guard let checksum, checksum.count == 64, checksum.allSatisfy(\.isHexDigit) else {
            throw UpdateError.missingChecksum
        }
        return checksum
    }

    private func validateApplication(at url: URL, expectedVersion: String) throws {
        guard let candidate = Bundle(url: url),
              candidate.bundleIdentifier == bundle.bundleIdentifier,
              candidate.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == expectedVersion,
              candidate.object(forInfoDictionaryKey: "SiftUpdateRepository") as? String == repository,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              FileManager.default.isExecutableFile(
                atPath: url.appendingPathComponent("Contents/Helpers/SiftUpdater").path
              ) else {
            throw UpdateError.invalidApplication
        }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { throw UpdateError.invalidSignature }
        let flags = SecCSFlags(
            rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSRestrictSymlinks
        )
        guard SecStaticCodeCheckValidity(staticCode, flags, nil) == errSecSuccess else {
            throw UpdateError.invalidSignature
        }
        if let currentTeam = signingTeam(for: bundle.bundleURL),
           signingTeam(for: url) != currentTeam {
            throw UpdateError.invalidSignature
        }
    }

    private func signingTeam(for url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 120
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }

    static func isValidRepository(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
    }

    static func isAllowedDownloadURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.path.contains("/releases/download/")
    }

    static func isAllowedReleaseURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.path.contains("/releases/tag/")
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func validate(response: URLResponse, allowedHosts: Set<String>) throws {
        guard let response = response as? HTTPURLResponse,
              200..<300 ~= response.statusCode,
              response.url?.scheme == "https",
              response.url?.host.map(allowedHosts.contains) == true else {
            throw UpdateError.invalidResponse
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: URL
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case digest
    }
}

enum UpdateError: LocalizedError, Equatable {
    case notConfigured, invalidResponse, invalidRelease, missingChecksum, checksumMismatch
    case invalidArchive, invalidApplication, invalidSignature, notRunningFromApplication
    case installLocationNotWritable, missingInstaller

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Updates become available in GitHub release builds"
        case .invalidResponse: return "GitHub returned an invalid response"
        case .invalidRelease: return "The latest GitHub release is incomplete"
        case .missingChecksum: return "The release has no SHA-256 checksum"
        case .checksumMismatch: return "The downloaded update failed verification"
        case .invalidArchive: return "The update archive could not be opened"
        case .invalidApplication: return "The update is not a valid Sift app"
        case .invalidSignature: return "The update's code signature is invalid"
        case .notRunningFromApplication: return "Run Sift from its app bundle to update"
        case .installLocationNotWritable: return "This installation cannot be updated in place"
        case .missingInstaller: return "The update helper is missing"
        }
    }
}
