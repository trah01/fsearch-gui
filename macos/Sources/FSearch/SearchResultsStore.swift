import Foundation

enum ResultColumn: String, CaseIterable, Sendable {
    case name, path, kind, size, modified, created
    var title: String {
        switch self {
        case .name: return "文件名"
        case .path: return "路径"
        case .kind: return "种类"
        case .size: return "大小"
        case .modified: return "修改时间"
        case .created: return "创建时间"
        }
    }
}

struct ResultSort: Equatable, Sendable {
    let column: ResultColumn
    let ascending: Bool

    func precedes(_ a: SearchHit, _ b: SearchHit) -> Bool {
        let comparison: ComparisonResult
        switch column {
        case .name: comparison = a.name.localizedStandardCompare(b.name)
        case .path: comparison = a.path.localizedStandardCompare(b.path)
        case .kind: comparison = a.kindText.localizedStandardCompare(b.kindText)
        case .size: comparison = a.size == b.size ? .orderedSame : a.size < b.size ? .orderedAscending : .orderedDescending
        case .modified: comparison = a.modified.compare(b.modified)
        case .created: comparison = (a.created ?? .distantPast).compare(b.created ?? .distantPast)
        }
        if comparison == .orderedSame { return a.path < b.path }
        return comparison == (ascending ? .orderedAscending : .orderedDescending)
    }
}

struct ResultsSnapshot: Sendable {
    let hits: [SearchHit]
    let positions: [String: Int]
    let generation: Int
    let revision: Int
    let orderingRevision: Int
}

/// Deduplication, sorting and row lookup construction run away from the UI.
actor SearchResultsStore {
    private var rows: [SearchHit] = []
    private var positions: [String: Int] = [:]
    private var generation = -1
    private var revision = 0
    private var originalRows: [SearchHit] = []
    private var sort: ResultSort?
    private var directoriesFirst = false
    private var orderingRevision = -1

    func replace(_ incoming: [SearchHit], generation: Int, sort: ResultSort?, directoriesFirst: Bool, orderingRevision: Int) throws -> ResultsSnapshot {
        try Task.checkCancellation()
        configure(sort: sort, directoriesFirst: directoriesFirst, revision: orderingRevision)
        rows = []
        positions = [:]
        originalRows = []
        rows.reserveCapacity(incoming.count)
        positions.reserveCapacity(incoming.count)
        self.generation = generation
        for (index, hit) in incoming.enumerated() {
            if index % 1024 == 0 { try Task.checkCancellation() }
            guard positions[hit.path] == nil else { continue }
            positions[hit.path] = rows.count
            rows.append(hit)
        }
        originalRows = rows
        if self.sort != nil || self.directoriesFirst { reorder() }
        revision += 1
        return ResultsSnapshot(hits: rows, positions: positions, generation: generation, revision: revision,
            orderingRevision: self.orderingRevision)
    }

    func sorted(by sort: ResultSort?, directoriesFirst: Bool, orderingRevision: Int, generation: Int) throws -> ResultsSnapshot? {
        try Task.checkCancellation()
        configure(sort: sort, directoriesFirst: directoriesFirst, revision: orderingRevision)
        guard generation == self.generation else { return nil }
        reorder()
        revision += 1
        return ResultsSnapshot(hits: rows, positions: positions, generation: generation, revision: revision,
            orderingRevision: self.orderingRevision)
    }

    private func configure(sort: ResultSort?, directoriesFirst: Bool, revision: Int) {
        guard revision >= orderingRevision else { return }
        self.sort = sort
        self.directoriesFirst = directoriesFirst
        orderingRevision = revision
    }

    private func reorder() {
        let directoriesFirst = self.directoriesFirst
        if let sort {
            rows.sort { a, b in
                if directoriesFirst && a.isDirectory != b.isDirectory { return a.isDirectory }
                return sort.precedes(a, b)
            }
        } else if directoriesFirst {
            // Stable partition preserves relevance in linear time.
            rows = []
            rows.reserveCapacity(originalRows.count)
            for hit in originalRows where hit.isDirectory { rows.append(hit) }
            for hit in originalRows where !hit.isDirectory { rows.append(hit) }
        } else {
            rows = originalRows
        }
        rebuildPositions()
    }

    private func rebuildPositions() {
        positions = [:]
        positions.reserveCapacity(rows.count)
        for (index, hit) in rows.enumerated() { positions[hit.path] = index }
    }
}
