import Foundation

/// One complete result set shared by all category views of the same search.
/// Type membership comes from the engine, so its extension rules stay in Rust.
struct SearchCatalog: Sendable {
    let key: [String]
    let entries: [SearchHit]
    let types: [String]

    func filtered(_ request: [String: Any]) throws -> [SearchHit] {
        let type = request["type"] as? String
        let kind = request["kind"] as? String
        let extensions = Set((request["ext"] as? String ?? "").split(separator: ",").map(String.init))
        guard type != nil || kind != nil || !extensions.isEmpty else { return entries }
        let typeMask = type.flatMap { types.firstIndex(of: $0) }.map { UInt8(1 << $0) }
        let expectedKind: UInt8? = kind == "file" ? 0 : kind == "dir" ? 1 : nil
        var matches: [SearchHit] = []
        matches.reserveCapacity(entries.count)
        for (index, hit) in entries.enumerated() {
            if index % 1024 == 0 { try Task.checkCancellation() }
            if let mask = typeMask, hit.typeMask & mask == 0 { continue }
            if let expectedKind, hit.kind != expectedKind { continue }
            if !extensions.isEmpty {
                guard let dot = hit.path.lastIndex(of: ".") else { continue }
                let suffix = hit.path[hit.path.index(after: dot)...]
                guard !suffix.contains("/"), extensions.contains(suffix.lowercased()) else { continue }
            }
            matches.append(hit)
        }
        return matches
    }
}
