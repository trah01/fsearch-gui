import Foundation
import Darwin

/// A framed session shares the CLI daemon and its existing index.
actor SearchClient {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var pending = Data()
    private var catalog: SearchCatalog?
    private var catalogRevision = 0
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 20) { self.timeout = timeout }

    /// Validate scope and decode index-only rows on the background executor.
    func search(_ request: [String: Any], catalogKey: [String], refresh: Bool) throws -> SearchBatch {
        if refresh { catalog = nil }
        if catalog?.key == catalogKey { return try batch(request: request) }
        if let path = request["in"] as? String {
            var isDirectory: ObjCBool = false
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ClientError.message("请选择有效的文件夹，或粘贴完整的文件夹路径。")
            }
        }
        var baseRequest = request
        for field in ["type", "kind", "ext"] { baseRequest.removeValue(forKey: field) }
        baseRequest["format"] = "binary-v1"
        let result = try fetchRows(baseRequest)
        guard let types = result.response.types else { throw ClientError.message("搜索服务返回了无法识别的数据。") }
        self.catalog = SearchCatalog(key: catalogKey, entries: result.hits, types: types)
        catalogRevision += 1
        return try batch(request: request)
    }

    func releaseCatalog() { catalog = nil }

    func searchPage(_ request: [String: Any], cursor: Data?) throws -> SearchPageBatch {
        catalog = nil
        var request = request
        request["op"] = "search-page"
        request["limit"] = 3000
        request["format"] = "binary-v1"
        if let cursor { request["cursor"] = try JSONSerialization.jsonObject(with: cursor) }
        let result = try fetchRows(request, maximumRows: 3000)
        let fields = try JSONSerialization.jsonObject(with: result.header) as? [String: Any]
        let next: Data?
        if let value = fields?["next"], !(value is NSNull) {
            next = try JSONSerialization.data(withJSONObject: value)
        } else { next = nil }
        return SearchPageBatch(hits: result.hits, next: next, total: result.response.total)
    }

    private func fetchRows(_ request: [String: Any], maximumRows: Int? = nil) throws -> (hits: [SearchHit], response: DesktopSearchResponse, header: Data) {
        do {
            let header = try exchange(request)
            let response = try JSONDecoder().decode(DesktopSearchResponse.self, from: header)
            guard response.ok else { throw ClientError.message(response.error ?? "搜索失败，请重试。") }
            guard response.binary_version == 1, let length = response.binary_bytes, let count = response.count,
                  length >= 0, count >= 0, count <= length / 20,
                  maximumRows.map({ count <= $0 }) ?? true else {
                throw ClientError.message("搜索服务返回了无法识别的数据。")
            }
            let hits = try SearchBinaryRows.decode(readPayload(length), count: count)
            return (hits, response, header)
        } catch {
            disconnect()
            throw error
        }
    }

    private func batch(request: [String: Any]) throws -> SearchBatch {
        let filter = ["type", "kind", "ext"].map { request[$0] as? String ?? "" }
        return SearchBatch(hits: try catalog!.filtered(request), catalogRevision: catalogRevision, filter: filter)
    }

    private func readPayload(_ length: Int) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data()
        data.reserveCapacity(length)
        let available = min(length, pending.count)
        data.append(pending.prefix(available))
        pending = Data(pending.dropFirst(available))
        var buffer = [UInt8](repeating: 0, count: 65536)
        while data.count < length {
            let count = try read(into: &buffer, limit: min(buffer.count, length - data.count), deadline: deadline)
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private func connect() throws {
        if process?.isRunning == true { return }
        let executable = try executableURL()
        let task = Process()
        let up = Pipe(), down = Pipe()
        task.executableURL = executable
        task.arguments = ["desktop-stdio"]
        task.standardInput = up
        task.standardOutput = down
        task.standardError = FileHandle.nullDevice
        try task.run()
        process = task
        input = up.fileHandleForWriting
        output = down.fileHandleForReading
        pending.removeAll()
        catalog = nil
    }

    private func executableURL() throws -> URL {
        let bundled = Bundle.main.url(forResource: "fsearch", withExtension: nil)
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("target/release/fsearch")
        let installed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/fsearch")
        guard let executable = [bundled, local, installed].compactMap({ $0 }).first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else { throw ClientError.message("未找到搜索引擎，请先运行 scripts/build-app.sh 构建应用。") }
        return executable
    }

    func restartEngine() throws {
        disconnect()
        let task = Process()
        task.executableURL = try executableURL()
        task.arguments = ["restart"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw ClientError.message("无法重新载入权限，请退出应用后重新打开。")
        }
    }

    private func disconnect() {
        input?.closeFile()
        output?.closeFile()
        if process?.isRunning == true { process?.terminate() }
        input = nil
        output = nil
        process = nil
        pending.removeAll()
        catalog = nil
    }

    func request(_ request: [String: Any]) throws -> [String: Any] {
        guard let response = try JSONSerialization.jsonObject(with: exchange(request)) as? [String: Any] else {
            throw ClientError.message("搜索服务返回了无法识别的数据。")
        }
        return response
    }

    private func exchange(_ request: [String: Any]) throws -> Data {
        do {
            try Task.checkCancellation()
            try connect()
            var data = try JSONSerialization.data(withJSONObject: request)
            data.append(10)
            try input?.write(contentsOf: data)
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            var complete = pending.contains(10)
            var buffer = [UInt8](repeating: 0, count: 65536)
            while !complete {
                let count = try read(into: &buffer, limit: buffer.count, deadline: deadline)
                complete = buffer.prefix(count).contains(10)
                pending.append(contentsOf: buffer.prefix(count))
            }
            let end = pending.firstIndex(of: 10)!
            let line = pending[..<end]
            // Transfer the full response buffer instead of retaining/copying
            // hundreds of MB in the connection after every desktop search.
            pending = end == pending.index(before: pending.endIndex) ? Data() : Data(pending[pending.index(after: end)...])
            return line
        } catch {
            disconnect()
            throw error
        }
    }

    private func read(into buffer: inout [UInt8], limit: Int, deadline: TimeInterval) throws -> Int {
        while true {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw ClientError.message("搜索响应超时，请稍后重试。首次使用时，建立索引可能需要一些时间。")
            }
            guard let output else { throw ClientError.message("搜索服务连接已断开，请点击重试。") }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if ready == 0 { continue }
            let count = Darwin.read(output.fileDescriptor, &buffer, limit)
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard count > 0 else { throw ClientError.message("搜索服务连接已断开，请点击重试。") }
            return count
        }
    }
}

private struct DesktopSearchResponse: Decodable {
    let ok: Bool
    let binary_version: Int?
    let binary_bytes: Int?
    let count: Int?
    let types: [String]?
    let error: String?
    let total: Int?
}

struct SearchBatch: Sendable {
    let hits: SearchRows
    let catalogRevision: Int
    let filter: [String]

    init(hits: SearchRows, catalogRevision: Int, filter: [String]) {
        self.hits = hits
        self.catalogRevision = catalogRevision
        self.filter = filter
    }

    init(hits: [SearchHit], catalogRevision: Int, filter: [String]) {
        self.init(hits: SearchRows(hits), catalogRevision: catalogRevision, filter: filter)
    }
}

struct SearchPageBatch: Sendable {
    let hits: [SearchHit]
    let next: Data?
    let total: Int?
}

enum ClientError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
