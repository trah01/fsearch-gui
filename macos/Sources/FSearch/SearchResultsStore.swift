import Foundation

enum ResultColumn: String, CaseIterable, Sendable {
    case name, path, kind, size, modified, created
    var title: String {
        switch self {
        case .name: return L("文件名")
        case .path: return L("路径")
        case .kind: return L("种类")
        case .size: return L("大小")
        case .modified: return L("修改时间")
        case .created: return L("创建时间")
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

/// One path hash table per result set. Sorts only replace the compact inverse
/// permutation, avoiding rehashing millions of paths for each ordering.
struct ResultRowLookup: Sendable {
    let base: [String: Int]
    let inverse: [UInt32]?

    init(base: [String: Int] = [:], inverse: [UInt32]? = nil) {
        self.base = base
        self.inverse = inverse
    }

    subscript(path: String) -> Int? {
        guard let index = base[path] else { return nil }
        guard let inverse else { return index }
        let row = inverse[index]
        return row == .max ? nil : Int(row)
    }
}

struct ResultsSnapshot: Sendable {
    let hits: SearchRows
    let positions: ResultRowLookup
    let generation: Int
    let revision: Int
    let orderingRevision: Int
}

/// Immutable result sets retain compact sort indexes across type/direction
/// changes. All preparation stays off the UI executor and can be cancelled.
actor SearchResultsStore {
    private final class ResultSet {
        let originalRows: SearchRows
        let basePositions: [String: Int]
        let sorter: SearchResultSorter
        let sourceRows: [UInt32]?
        let sourceCount: Int
        var rows: SearchRows
        var lookup: ResultRowLookup
        var sort: ResultSort?
        var directoriesFirst = false

        init(rows: SearchRows, positions: [String: Int], sharedNames: SharedResultNameRanks,
             parent: ResultSet? = nil, sourceRows: [UInt32]? = nil, sourcePositions: [UInt32]? = nil) {
            originalRows = rows
            basePositions = positions
            sorter = SearchResultSorter(rows, sharedNames: sharedNames, parent: parent?.sorter,
                parentRows: sourceRows, parentPositions: sourcePositions)
            self.sourceRows = sourceRows
            sourceCount = parent?.originalRows.count ?? rows.count
            self.rows = rows
            lookup = ResultRowLookup(base: positions, inverse: sourcePositions)
        }
    }

    private var current: ResultSet?
    private var catalogRoot: ResultSet?
    private var generation = -1
    private var revision = 0
    private var orderingRevision = -1
    private var sort: ResultSort?
    private var directoriesFirst = false
    private var catalogRevision = -1
    private var cache: [[String]: ResultSet] = [:]
    private var cacheOrder: [[String]] = []
    private let sharedNames: SharedResultNameRanks

    init(nameRankCache: URL? = ResultNameRankCache.defaultURL) {
        sharedNames = SharedResultNameRanks(cacheURL: nameRankCache)
    }

    /// This is index preparation, not an interactive sort. It does not change
    /// the visible order and runs while the current list remains usable.
    func prepareSorting(generation: Int) async throws {
        let cancellation = ResultSortCancellation()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard generation == self.generation, let current else { return }
            try current.sorter.prepare(cancellation: cancellation)
        } onCancel: { cancellation.cancel() }
    }

    func replace(_ batch: SearchBatch, generation: Int, sort: ResultSort?, directoriesFirst: Bool,
                 orderingRevision: Int) async throws -> ResultsSnapshot {
        let cancellation = ResultSortCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            configure(sort: sort, directoriesFirst: directoriesFirst, revision: orderingRevision)
            if catalogRevision != batch.catalogRevision {
                cache.removeAll()
                cacheOrder.removeAll()
                catalogRoot = nil
                catalogRevision = batch.catalogRevision
            }
            let result: ResultSet
            if let cached = cache[batch.filter] { result = cached }
            else { result = try prepare(batch.hits, cancellation: cancellation) }
            try arrange(result, cancellation: cancellation)
            try cancellation.check()
            current = result
            self.generation = generation
            cache.removeValue(forKey: batch.filter)
            cacheOrder.removeAll { $0 == batch.filter }
            // Retain row buffers for at most two complete result sets. This
            // bounds category/sort caches even for overlapping custom filters.
            while !cacheOrder.isEmpty && (cacheOrder.count >= 4 ||
                cache.values.reduce(0, { $0 + $1.originalRows.count }) + result.originalRows.count > max(batch.hits.count, cache.values.map { $0.originalRows.count }.max() ?? 0) * 2) {
                cache.removeValue(forKey: cacheOrder.removeFirst())
            }
            cache[batch.filter] = result
            cacheOrder.append(batch.filter)
            return snapshot(result)
        } onCancel: { cancellation.cancel() }
    }

    func sorted(by sort: ResultSort?, directoriesFirst: Bool, orderingRevision: Int,
                generation: Int) async throws -> ResultsSnapshot? {
        let cancellation = ResultSortCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard generation == self.generation, let current else { return nil }
            configure(sort: sort, directoriesFirst: directoriesFirst, revision: orderingRevision)
            try arrange(current, cancellation: cancellation)
            return snapshot(current)
        } onCancel: { cancellation.cancel() }
    }

    private func configure(sort: ResultSort?, directoriesFirst: Bool, revision: Int) {
        guard revision >= orderingRevision else { return }
        self.sort = sort
        self.directoriesFirst = directoriesFirst
        orderingRevision = revision
    }

    private func prepare(_ incoming: SearchRows, cancellation: ResultSortCancellation) throws -> ResultSet {
        if let parent = catalogRoot, parent.originalRows.count >= incoming.count {
            var sourceRows: [UInt32] = []
            sourceRows.reserveCapacity(incoming.count)
            var sourcePositions = [UInt32](repeating: .max, count: parent.originalRows.count)
            for (index, hit) in incoming.enumerated() {
                if index & 4095 == 0 { try cancellation.check() }
                guard let row = parent.basePositions[hit.path], sourcePositions[row] == .max else { break }
                sourceRows.append(UInt32(row))
                sourcePositions[row] = UInt32(index)
            }
            if sourceRows.count == incoming.count {
                return ResultSet(rows: incoming, positions: parent.basePositions, sharedNames: sharedNames,
                    parent: parent, sourceRows: sourceRows, sourcePositions: sourcePositions)
            }
        }
        var positions: [String: Int] = [:]
        positions.reserveCapacity(incoming.count)
        var hasDuplicates = false
        for (index, hit) in incoming.enumerated() {
            if index & 4095 == 0 { try cancellation.check() }
            if let previous = positions.updateValue(index, forKey: hit.path) {
                positions[hit.path] = previous
                hasDuplicates = true
            }
        }
        if !hasDuplicates {
            let result = ResultSet(rows: incoming, positions: positions, sharedNames: sharedNames)
            if incoming.count >= (catalogRoot?.originalRows.count ?? 0) { catalogRoot = result }
            return result
        }
        var rows: [SearchHit] = []
        rows.reserveCapacity(positions.count)
        for (index, hit) in incoming.enumerated() {
            if index & 4095 == 0 { try cancellation.check() }
            if positions[hit.path] == index { rows.append(hit) }
        }
        positions.removeAll(keepingCapacity: true)
        for (index, hit) in rows.enumerated() { positions[hit.path] = index }
        return ResultSet(rows: SearchRows(rows), positions: positions, sharedNames: sharedNames)
    }

    private func arrange(_ result: ResultSet, cancellation: ResultSortCancellation) throws {
        guard result.sort != sort || result.directoriesFirst != directoriesFirst else { return }
        let order = try result.sorter.order(by: sort, directoriesFirst: directoriesFirst, cancellation: cancellation)
        let rows: SearchRows
        let lookup: ResultRowLookup
        if sort == nil && !directoriesFirst {
            rows = result.originalRows
            if let sourceRows = result.sourceRows {
                var inverse = [UInt32](repeating: .max, count: result.sourceCount)
                for (position, row) in sourceRows.enumerated() {
                    if position & 4095 == 0 { try cancellation.check() }
                    inverse[Int(row)] = UInt32(position)
                }
                lookup = ResultRowLookup(base: result.basePositions, inverse: inverse)
            } else { lookup = ResultRowLookup(base: result.basePositions) }
        } else {
            var inverse = [UInt32](repeating: .max, count: result.sourceCount)
            for (position, row) in order.enumerated() {
                if position & 4095 == 0 { try cancellation.check() }
                let source = result.sourceRows.map { Int($0[Int(row)]) } ?? Int(row)
                inverse[source] = UInt32(position)
            }
            rows = result.originalRows.reordered(by: order)
            lookup = ResultRowLookup(base: result.basePositions, inverse: inverse)
        }
        try cancellation.check()
        result.rows = rows
        result.lookup = lookup
        result.sort = sort
        result.directoriesFirst = directoriesFirst
    }

    private func snapshot(_ result: ResultSet) -> ResultsSnapshot {
        revision += 1
        return ResultsSnapshot(hits: result.rows, positions: result.lookup, generation: generation,
            revision: revision, orderingRevision: orderingRevision)
    }
}
