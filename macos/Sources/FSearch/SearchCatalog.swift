import Foundation

/// One complete result set shared by all category views of the same search.
/// Type membership comes from the engine, so its extension rules stay in Rust.
struct SearchCatalog: Sendable {
    let key: [String]
    let entries: [SearchHit]
    let types: [String]
    private let typeRows: [[UInt32]]
    private let directoryRows: [UInt32]
    private var cachedFilters: [[String]: [UInt32]] = [:]
    private var filterOrder: [[String]] = []

    init(key: [String], entries: [SearchHit], types: [String]) {
        self.key = key
        self.entries = entries
        self.types = types
        var buckets = [[UInt32]](repeating: [], count: min(types.count, 8))
        var directories: [UInt32] = []
        // A compact inverted index: category switches visit matching row IDs
        // rather than scanning every path again. Paths remain shared by COW.
        for (index, hit) in entries.enumerated() {
            var mask = hit.typeMask
            while mask != 0 {
                let bit = mask.trailingZeroBitCount
                if bit < buckets.count { buckets[bit].append(UInt32(index)) }
                mask &= mask - 1
            }
            if hit.isDirectory { directories.append(UInt32(index)) }
        }
        typeRows = buckets
        directoryRows = directories
    }

    mutating func filtered(_ request: [String: Any]) throws -> SearchRows {
        let type = request["type"] as? String
        let kind = request["kind"] as? String
        let extensions = Set((request["ext"] as? String ?? "").split(separator: ",").map(String.init))
        guard type != nil || kind != nil || !extensions.isEmpty else { return SearchRows(entries) }
        let key = [type ?? "", kind ?? "", extensions.sorted().joined(separator: ",")]
        if let cached = cachedFilters[key] { return SearchRows(entries, order: cached) }
        let typeIndex = type.flatMap { types.firstIndex(of: $0) }
        let candidates = typeIndex.flatMap { typeRows.indices.contains($0) ? typeRows[$0] : nil }
            ?? (kind == "dir" ? directoryRows : nil)
        let expectedKind: UInt8? = kind == "file" ? 0 : kind == "dir" ? 1 : nil
        var matches: [UInt32] = []
        matches.reserveCapacity(candidates?.count ?? min(entries.count, 4096))
        for position in 0..<(candidates?.count ?? entries.count) {
            if position % 1024 == 0 { try Task.checkCancellation() }
            let row = candidates?[position] ?? UInt32(position)
            let hit = entries[Int(row)]
            if let expectedKind, hit.kind != expectedKind { continue }
            if !extensions.isEmpty {
                let bytes = hit.path.utf8
                guard let dot = bytes.lastIndex(where: { $0 == 46 || $0 == 47 }), bytes[dot] == 46 else { continue }
                let suffix = hit.path[bytes.index(after: dot)...]
                guard extensions.contains(suffix.lowercased()) else { continue }
            }
            matches.append(row)
        }
        if filterOrder.count == 8 { cachedFilters.removeValue(forKey: filterOrder.removeFirst()) }
        filterOrder.append(key)
        cachedFilters[key] = matches
        return SearchRows(entries, order: matches)
    }
}
