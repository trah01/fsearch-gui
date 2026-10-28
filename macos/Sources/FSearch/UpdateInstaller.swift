import AppKit
import Foundation

enum UpdateInstaller {
    static let pendingDirectoryKey = "FSearch.pendingUpdateDirectory"

    struct PreparedUpdate: Sendable {
        let directory: URL
        let target: URL
    }

    /// Prepare and validate a sibling bundle so replacement stays on the same filesystem.
    static func prepare(archive: URL, version: String, target: URL) throws -> PreparedUpdate {
        let manager = FileManager.default
        let target = target.resolvingSymlinksInPath()
        let parent = target.deletingLastPathComponent()
        guard target.pathExtension == "app", !target.path.contains("/AppTranslocation/"),
              manager.isWritableFile(atPath: parent.path), manager.isWritableFile(atPath: target.path) else {
            throw UpdateError(L("请先将 FSearch 移到可写的“应用程序”文件夹，再安装更新。"))
        }
        let entries = try run("/usr/bin/zipinfo", ["-1", archive.path]).split(whereSeparator: \.isNewline)
        guard !entries.isEmpty, entries.count < 20_000,
              entries.allSatisfy({ entry in
                  let parts = entry.split(separator: "/")
                  return !entry.hasPrefix("/") && !entry.contains("\\")
                      && !parts.contains("..") && !parts.contains(".")
                      && (parts.first == "FSearch.app" || parts.first == "__MACOSX")
              }) else { throw UpdateError(L("更新包内容无效。")) }
        // This app ships no symlinks. Reject them before extracting to prevent archive traversal.
        let listing = try run("/usr/bin/zipinfo", ["-l", archive.path])
        guard !listing.split(whereSeparator: \.isNewline).contains(where: { $0.first == "l" }) else {
            throw UpdateError(L("更新包内容无效。"))
        }
        let directory = parent.appendingPathComponent(".FSearch-update-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        do {
            try run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
            let app = directory.appendingPathComponent("FSearch.app")
            let info = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
            guard let properties = try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any],
                  properties["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
                  properties["CFBundleShortVersionString"] as? String == version,
                  properties["CFBundleVersion"] as? String == version,
                  properties["CFBundleExecutable"] as? String == "FSearch" else {
                throw UpdateError(L("更新包的应用或版本不匹配。"))
            }
            if let minimum = properties["LSMinimumSystemVersion"] as? String {
                let fields = minimum.split(separator: ".", omittingEmptySubsequences: false)
                let parts = fields.compactMap { Int($0) }
                guard !parts.isEmpty, parts.count == fields.count, parts.count <= 3,
                      parts.allSatisfy({ $0 >= 0 }),
                      ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(
                        majorVersion: parts[0], minorVersion: parts.count > 1 ? parts[1] : 0,
                        patchVersion: parts.count > 2 ? parts[2] : 0)) else {
                    throw UpdateError(L("此版本需要更新的 macOS。"))
                }
            }
            #if arch(arm64)
            let architecture = "arm64"
            #else
            let architecture = "x86_64"
            #endif
            let architectures = try run("/usr/bin/lipo", ["-archs", app.appendingPathComponent("Contents/MacOS/FSearch").path])
            guard architectures.split(whereSeparator: \.isWhitespace).contains(Substring(architecture)) else {
                throw UpdateError(L("此版本不支持当前 Mac。"))
            }
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
            let resources = Bundle.main.url(forResource: "FSearch_FSearch", withExtension: "bundle")
                .flatMap(Bundle.init(url:)) ?? Bundle.module
            guard let script = resources.url(forResource: "install-update", withExtension: "sh") else {
                throw UpdateError(L("找不到更新安装程序。"))
            }
            try manager.copyItem(at: script, to: directory.appendingPathComponent("install-update.sh"))
            return PreparedUpdate(directory: directory, target: target)
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    @MainActor
    static func installAndRelaunch(_ update: PreparedUpdate) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [update.directory.appendingPathComponent("install-update.sh").path,
                             String(ProcessInfo.processInfo.processIdentifier), update.target.path, update.directory.path]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        let log = update.directory.appendingPathComponent("install.log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        process.standardOutput = output
        process.standardError = output
        UserDefaults.standard.set(update.directory.path, forKey: pendingDirectoryKey)
        do { try process.run() }
        catch {
            UserDefaults.standard.removeObject(forKey: pendingDirectoryKey)
            try? FileManager.default.removeItem(at: update.directory)
            throw error
        }
        NSApp.terminate(nil)
    }

    /// Only clean up after the replacement app has actually launched successfully.
    @MainActor
    static func finishPreviousInstallation() -> Bool {
        guard let path = UserDefaults.standard.string(forKey: pendingDirectoryKey) else { return true }
        UserDefaults.standard.removeObject(forKey: pendingDirectoryKey)
        let directory = URL(fileURLWithPath: path).standardizedFileURL
        let parent = Bundle.main.bundleURL.resolvingSymlinksInPath().deletingLastPathComponent()
        guard directory.deletingLastPathComponent() == parent,
              directory.lastPathComponent.hasPrefix(".FSearch-update-") else { return false }
        let result = try? String(contentsOf: directory.appendingPathComponent("result"), encoding: .utf8)
        guard result == "success\n" else { return false }
        try? FileManager.default.removeItem(at: directory)
        return true
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError(L("无法准备更新包，请重新下载或前往 GitHub 安装。"))
        }
        return String(data: output, encoding: .utf8) ?? ""
    }
}
