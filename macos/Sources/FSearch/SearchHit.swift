import Foundation

enum SearchFormatting {
    static let date = Date.FormatStyle.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().second()

    static func size(_ bytes: Int64) -> String {
        bytes == 0 ? "0kb" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Rows use index data only; loading results never stats every file.
struct SearchHit: Identifiable, Sendable, Decodable {
    let path: String
    let size: Int64
    let modified: Date
    let kind: UInt8
    let typeMask: UInt8
    var isDirectory: Bool { kind == 1 }
    var fileURL: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }
    var name: String { String(nameSlice) }
    var nameSlice: Substring {
        let bytes = path.utf8
        guard let slash = bytes.lastIndex(of: 47) else { return path[...] }
        let start = bytes.index(after: slash)
        // Indexed paths normally have no trailing separator. Preserve the
        // existing Foundation behavior for roots and exceptional inputs.
        guard start != path.endIndex else { return Substring((path as NSString).lastPathComponent) }
        return path[start...]
    }
    var created: Date? { nil }
    var sizeText: String { isDirectory ? "—" : SearchFormatting.size(size) }
    var modifiedText: String { modified == .distantPast ? "—" : modified.formatted(SearchFormatting.date) }
    var createdText: String { "—" }
    var id: String { path }
    var kindText: String {
        if (path as NSString).pathExtension.lowercased() == "app" { return "应用程序" }
        if isDirectory { return "文件夹" }
        let ext = (path as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "文件" : "\(ext) 文件"
    }

    init(path: String, kind: UInt8, size: Int64, modified: Date, typeMask: UInt8) {
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
        self.typeMask = typeMask
    }

    /// Compact desktop JSON rows: [path, kind, size, modification time, type mask].
    /// Keep raw metadata here; only visible rows format names and dates.
    init(from decoder: Decoder) throws {
        try Task.checkCancellation()
        var row = try decoder.unkeyedContainer()
        path = try row.decode(String.self)
        kind = try row.decode(UInt8.self)
        size = try row.decode(Int64.self)
        modified = Date(timeIntervalSince1970: try row.decode(Double.self))
        typeMask = try row.decode(UInt8.self)
    }
}
