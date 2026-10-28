import CryptoKit
import Foundation

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct UpdateVersion: Comparable, Sendable {
    let components: [Int]

    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        components = numbers
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

struct GitHubUpdateRelease: Sendable {
    let version: String
    let archive: Asset
    let checksums: Asset

    struct Asset: Decodable, Sendable {
        let name: String
        let size: Int64
        let browserDownloadURL: URL
        let digest: String?
        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case browserDownloadURL = "browser_download_url"
        }
    }

    private struct Release: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case draft, prerelease, assets
            case tagName = "tag_name"
        }
    }

    static func latest() async throws -> Self? {
        let repository = AppInformation.repository
        guard repository.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
              let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw UpdateError(L("更新地址无效。"))
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("FSearch/\(AppInformation.version)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        try validateResponse(response)
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease,
              let candidate = UpdateVersion(release.tagName),
              let current = UpdateVersion(AppInformation.version), candidate > current else { return nil }
        let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let names = [
            "FSearch-gui-\(version)-universal.zip", "FSearch-gui-\(version)-\(architecture).zip",
            "FSearch-\(version)-universal.zip", "FSearch-\(version)-\(architecture).zip"
        ]
        guard let asset = names.compactMap({ name in release.assets.first { $0.name == name } }).first,
              let checksums = release.assets.first(where: {
                  $0.name == String(asset.name.dropLast(4)) + ".sha256"
              }), asset.size > 0, asset.size <= 1_073_741_824,
              checksums.size > 0, checksums.size <= 1_048_576 else {
            throw UpdateError(L("此版本缺少适用于当前 Mac 的更新包或校验文件。"))
        }
        for item in [asset, checksums] {
            let url = item.browserDownloadURL
            guard url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil,
                  url.port == nil, url.query == nil, url.fragment == nil,
                  url.path == "/\(repository)/releases/download/\(release.tagName)/\(item.name)" else {
                throw UpdateError(L("更新地址无效。"))
            }
        }
        return Self(version: version, archive: asset, checksums: checksums)
    }

    /// HTTPS and GitHub's release checksum establish the download's source and integrity.
    func download() async throws -> URL {
        let (checksumData, checksumResponse) = try await URLSession.shared.data(from: checksums.browserDownloadURL)
        try Self.validateResponse(checksumResponse)
        guard checksumData.count <= 1_048_576,
              let text = String(data: checksumData, encoding: .utf8) else {
            throw UpdateError(L("更新校验文件无效。"))
        }
        let hashes = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { return nil }
            let name = parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "*", with: "")
            let hash = String(parts[0]).lowercased()
            return name == archive.name && Self.isSHA256(hash) ? hash : nil
        }
        guard hashes.count == 1, let expected = hashes.first else {
            throw UpdateError(L("更新校验文件无效。"))
        }
        if let digest = archive.digest {
            guard digest.lowercased() == "sha256:\(expected)" else {
                throw UpdateError(L("更新包校验失败，请重新下载。"))
            }
        }
        var request = URLRequest(url: archive.browserDownloadURL, timeoutInterval: 60)
        request.setValue("FSearch/\(AppInformation.version)", forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.validateResponse(response)
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, Int64(size) == archive.size,
              try Self.sha256(temporary) == expected else {
            throw UpdateError(L("更新包校验失败，请重新下载。"))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FSearch-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent(archive.name)
        do { try FileManager.default.moveItem(at: temporary, to: destination) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        return destination
    }

    private static func validateResponse(_ response: URLResponse) throws {
        let hosts = ["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let url = http.url, url.scheme == "https", let host = url.host, hosts.contains(host) else {
            throw UpdateError(L("GitHub 暂时无法提供更新，请稍后重试。"))
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func sha256(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
