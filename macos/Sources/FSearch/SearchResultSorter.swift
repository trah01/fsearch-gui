import Foundation
import CoreFoundation

/// Cancellation is also visible to GCD workers, which do not inherit the
/// calling Swift task's cancellation state.
final class ResultSortCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
    }
}

/// Immutable rows stay shared with the catalog. Only 32-bit row IDs move
/// during sorting; cached ascending orders serve both directions.
final class SharedResultNameRanks {
    private let cacheURL: URL?
    var values: [Substring: UInt64]

    init(cacheURL: URL? = nil) {
        self.cacheURL = cacheURL
        values = ResultNameRankCache.load(cacheURL)
    }

    func update(_ values: [Substring: UInt64]) {
        self.values = values
        ResultNameRankCache.save(values, to: cacheURL)
    }
}

final class SearchResultSorter {
    private let hits: SearchRows
    private let sharedNames: SharedResultNameRanks?
    private let parent: SearchResultSorter?
    private let parentRows: [UInt32]?
    private let parentPositions: [UInt32]?
    private var pathOrder: [UInt32]?
    private struct ColumnOrder {
        let rows: [UInt32]
        let keys: [UInt64]
    }
    private var columns: [ResultColumn: ColumnOrder] = [:]
    private var columnUse: [ResultColumn] = []

    init(_ hits: SearchRows, sharedNames: SharedResultNameRanks? = nil,
         parent: SearchResultSorter? = nil, parentRows: [UInt32]? = nil, parentPositions: [UInt32]? = nil) {
        self.hits = hits
        self.sharedNames = sharedNames
        self.parent = parent
        self.parentRows = parentRows
        self.parentPositions = parentPositions
    }

    convenience init(_ hits: [SearchHit], sharedNames: SharedResultNameRanks? = nil) {
        self.init(SearchRows(hits), sharedNames: sharedNames)
    }

    func prepare(cancellation: ResultSortCancellation) throws {
        for column in [ResultColumn.name, .size, .modified] {
            _ = try prepared(column, cancellation: cancellation)
        }
    }

    func order(by sort: ResultSort?, directoriesFirst: Bool, cancellation: ResultSortCancellation) throws -> [UInt32] {
        try cancellation.check()
        var order: [UInt32]
        if let sort {
            let column = try prepared(sort.column, cancellation: cancellation)
            if sort.ascending { order = column.rows }
            else {
                // Reverse key groups, keeping path ascending within ties.
                // Reversing the entire array would reverse those ties too.
                order = []
                order.reserveCapacity(hits.count)
                var upper = column.rows.count
                while upper > 0 {
                    try cancellation.check()
                    var lower = upper - 1
                    let key = column.keys[Int(column.rows[lower])]
                    while lower > 0 && column.keys[Int(column.rows[lower - 1])] == key {
                        if lower & 4095 == 0 { try cancellation.check() }
                        lower -= 1
                    }
                    order.append(contentsOf: column.rows[lower..<upper])
                    upper = lower
                }
            }
        } else {
            order = (0..<hits.count).map { UInt32($0) }
        }
        guard directoriesFirst else { return order }
        var partitioned: [UInt32] = []
        partitioned.reserveCapacity(order.count)
        for directory in [true, false] {
            for (position, row) in order.enumerated() {
                if position & 4095 == 0 { try cancellation.check() }
                if hits[Int(row)].isDirectory == directory { partitioned.append(row) }
            }
        }
        return partitioned
    }

    private func prepared(_ column: ResultColumn, cancellation: ResultSortCancellation) throws -> ColumnOrder {
        if let cached = columns[column] {
            columnUse.removeAll { $0 == column }
            columnUse.append(column)
            return cached
        }
        if let parent, let parentRows, let parentPositions, let cached = parent.columns[column] {
            // A category is a subset of the same catalog. Filter an existing
            // global ordering instead of extracting/sorting its names again.
            var rows: [UInt32] = []
            rows.reserveCapacity(hits.count)
            for (position, row) in cached.rows.enumerated() {
                if position & 16383 == 0 { try cancellation.check() }
                let child = parentPositions[Int(row)]
                if child != .max { rows.append(child) }
            }
            var keys: [UInt64] = []
            keys.reserveCapacity(hits.count)
            for (position, row) in parentRows.enumerated() {
                if position & 16383 == 0 { try cancellation.check() }
                keys.append(cached.keys[Int(row)])
            }
            let result = ColumnOrder(rows: rows, keys: keys)
            remember(result, column: column)
            return result
        }
        let base: [UInt32]
        if let pathOrder { base = pathOrder }
        else {
            let rows = (0..<hits.count).map { UInt32($0) }
            let hits = self.hits
            base = try ParallelResultSort.sorted(rows, cancellation: cancellation) {
                hits[Int($0)].path < hits[Int($1)].path
            }
            try cancellation.check()
            pathOrder = base
        }
        let keys: [UInt64]
        switch column {
        case .size:
            keys = try numericKeys(cancellation) { UInt64(bitPattern: $0.size) ^ (1 << 63) }
        case .modified:
            keys = try numericKeys(cancellation) { Self.dateKey($0.modified) }
        case .created:
            keys = try numericKeys(cancellation) { Self.dateKey($0.created ?? .distantPast) }
        case .name, .path, .kind:
            keys = try textKeys(column, cancellation: cancellation)
        }
        let rows = try Self.radix(base, keys: keys, cancellation: cancellation)
        try cancellation.check()
        let result = ColumnOrder(rows: rows, keys: keys)
        // Three full columns at most: cache size grows with row count, rather
        // than retaining a full SearchHit array and path dictionary per sort.
        remember(result, column: column)
        return result
    }

    private func remember(_ result: ColumnOrder, column: ResultColumn) {
        if columnUse.count == 3 { columns.removeValue(forKey: columnUse.removeFirst()) }
        columns[column] = result
        columnUse.append(column)
    }

    private func numericKeys(_ cancellation: ResultSortCancellation, value: (SearchHit) -> UInt64) throws -> [UInt64] {
        var keys: [UInt64] = []
        keys.reserveCapacity(hits.count)
        for (index, hit) in hits.enumerated() {
            if index & 4095 == 0 { try cancellation.check() }
            keys.append(value(hit))
        }
        return keys
    }

    private static func dateKey(_ date: Date) -> UInt64 {
        let bits = date.timeIntervalSinceReferenceDate.bitPattern
        return bits & (1 << 63) == 0 ? bits ^ (1 << 63) : ~bits
    }

    private func textKeys(_ column: ResultColumn, cancellation: ResultSortCancellation) throws -> [UInt64] {
        if column == .name, let sharedNames, !sharedNames.values.isEmpty {
            var keys: [UInt64] = []
            keys.reserveCapacity(hits.count)
            for (index, hit) in hits.enumerated() {
                if index & 4095 == 0 { try cancellation.check() }
                guard let rank = sharedNames.values[hit.nameSlice] else { break }
                keys.append(rank)
            }
            if keys.count == hits.count { return keys }
        }
        var names: [NSString] = []
        var identifiers: [Substring: UInt32] = [:]
        var rowNames: [UInt32] = []
        rowNames.reserveCapacity(hits.count)
        for (index, hit) in hits.enumerated() {
            if index & 4095 == 0 { try cancellation.check() }
            let text: Substring
            switch column {
            case .name: text = hit.nameSlice
            case .kind: text = Substring(hit.kindText)
            default: text = hit.path[...]
            }
            if let identifier = identifiers[text] { rowNames.append(identifier) }
            else {
                let identifier = UInt32(names.count)
                identifiers[text] = identifier
                names.append(String(text) as NSString)
                rowNames.append(identifier)
            }
        }
        // Interning avoids comparing the same basename millions of times.
        // Keep Finder's actual locale/numeric rules instead of substituting
        // ASCII order or a hand-written natural comparator.
        let namesToSort = names.map { $0 as CFString }
        let lengths = names.map { $0.length }
        let locale = Locale.current as CFLocale
        let options: CFStringCompareFlags = [.compareCaseInsensitive, .compareNumerically, .compareWidthInsensitive, .compareForcedOrdering]
        let compare: (UInt32, UInt32) -> CFComparisonResult = { a, b in
            CFStringCompareWithOptionsAndLocale(namesToSort[Int(a)], namesToSort[Int(b)],
                CFRange(location: 0, length: lengths[Int(a)]), options, locale)
        }
        let candidates = try NaturalNamePreorder.sorted(names, cancellation: cancellation)
        let unique = try ParallelResultSort.sorted(candidates, cancellation: cancellation) {
            compare($0, $1) == .compareLessThan
        }
        var ranks = [UInt64](repeating: 0, count: names.count)
        var rank: UInt64 = 0
        for position in unique.indices {
            if position & 4095 == 0 { try cancellation.check() }
            if position > 0,
               compare(unique[position - 1], unique[position]) != .compareEqualTo {
                rank += 1
            }
            ranks[Int(unique[position])] = rank
        }
        var keys: [UInt64] = []
        keys.reserveCapacity(hits.count)
        for (index, name) in rowNames.enumerated() {
            if index & 4095 == 0 { try cancellation.check() }
            keys.append(ranks[Int(name)])
        }
        if column == .name, let sharedNames, identifiers.count >= sharedNames.values.count {
            var shared: [Substring: UInt64] = [:]
            shared.reserveCapacity(identifiers.count)
            for (index, entry) in identifiers.enumerated() {
                if index & 4095 == 0 { try cancellation.check() }
                shared[Substring(String(entry.key))] = ranks[Int(entry.value)]
            }
            sharedNames.update(shared)
        }
        return keys
    }

    /// Stable LSD radix sort: O(8n), independent of the number of equal sizes
    /// or timestamps. Stable passes preserve the path tie-break order.
    private static func radix(_ rows: [UInt32], keys: [UInt64], cancellation: ResultSortCancellation) throws -> [UInt32] {
        guard rows.count > 1 else { return rows }
        var source = rows
        var target = [UInt32](repeating: 0, count: rows.count)
        for shift in stride(from: 0, to: 64, by: 8) {
            var counts = [Int](repeating: 0, count: 256)
            for (position, row) in source.enumerated() {
                if position & 16383 == 0 { try cancellation.check() }
                counts[Int((keys[Int(row)] >> shift) & 255)] += 1
            }
            if counts.contains(rows.count) { continue }
            var total = 0
            for bucket in counts.indices {
                let count = counts[bucket]
                counts[bucket] = total
                total += count
            }
            for (position, row) in source.enumerated() {
                if position & 16383 == 0 { try cancellation.check() }
                let bucket = Int((keys[Int(row)] >> shift) & 255)
                target[counts[bucket]] = row
                counts[bucket] += 1
            }
            swap(&source, &target)
        }
        return source
    }
}

private enum ParallelResultSort {
    private final class Parts: @unchecked Sendable {
        let lock = NSLock()
        var values: [[UInt32]?]
        var error: Error?
        init(_ count: Int) { values = .init(repeating: nil, count: count) }
        func put(_ value: [UInt32], at index: Int) {
            lock.lock()
            values[index] = value
            lock.unlock()
        }
        func fail(_ error: Error) {
            lock.lock()
            self.error = error
            lock.unlock()
        }
    }

    static func sorted(_ rows: [UInt32], cancellation: ResultSortCancellation,
                       by precedes: @escaping (UInt32, UInt32) -> Bool) throws -> [UInt32] {
        let count = min(8, ProcessInfo.processInfo.activeProcessorCount, max(1, rows.count / 32768))
        let parts = Parts(count)
        DispatchQueue.concurrentPerform(iterations: count) { part in
            do {
                let lower = rows.count * part / count
                let upper = rows.count * (part + 1) / count
                var local = Array(rows[lower..<upper])
                var comparisons = 0
                try local.sort {
                    comparisons += 1
                    if comparisons & 4095 == 0 { try cancellation.check() }
                    return precedes($0, $1)
                }
                parts.put(local, at: part)
            } catch { parts.fail(error) }
        }
        if let error = parts.error { throw error }
        var runs = parts.values.map { $0! }
        while runs.count > 1 {
            let current = runs
            let merged = Parts((current.count + 1) / 2)
            DispatchQueue.concurrentPerform(iterations: merged.values.count) { part in
                do {
                    let left = current[part * 2]
                    guard part * 2 + 1 < current.count else { merged.put(left, at: part); return }
                    let right = current[part * 2 + 1]
                    // An approximate natural radix pass often leaves whole
                    // runs in their final locale order. Join those runs in
                    // bulk instead of repeating a localized comparison per row.
                    if left.isEmpty || right.isEmpty || !precedes(right[0], left[left.count - 1]) {
                        merged.put(left + right, at: part)
                        return
                    }
                    var output: [UInt32] = []
                    output.reserveCapacity(left.count + right.count)
                    var a = 0, b = 0
                    var leftWins = 0, rightWins = 0
                    while a < left.count && b < right.count {
                        if output.count & 4095 == 0 { try cancellation.check() }
                        if precedes(right[b], left[a]) {
                            output.append(right[b]); b += 1
                            rightWins += 1; leftWins = 0
                            if rightWins == 7 && b < right.count {
                                try cancellation.check()
                                let end = prefixEnd(from: b, to: right.count) { precedes(right[$0], left[a]) }
                                output.append(contentsOf: right[b..<end])
                                b = end; rightWins = 0
                            }
                        } else {
                            output.append(left[a]); a += 1
                            leftWins += 1; rightWins = 0
                            if leftWins == 7 && a < left.count {
                                try cancellation.check()
                                let end = prefixEnd(from: a, to: left.count) { !precedes(right[b], left[$0]) }
                                output.append(contentsOf: left[a..<end])
                                a = end; leftWins = 0
                            }
                        }
                    }
                    output.append(contentsOf: left[a...])
                    output.append(contentsOf: right[b...])
                    merged.put(output, at: part)
                } catch { merged.fail(error) }
            }
            if let error = merged.error { throw error }
            runs = merged.values.map { $0! }
        }
        try cancellation.check()
        return runs[0]
    }

    /// Galloping merge copies long ordered stretches in bulk. A handful of
    /// punctuation/locale exceptions must not cause millions of additional
    /// localized comparisons between otherwise ordered radix runs.
    private static func prefixEnd(from start: Int, to end: Int, while predicate: (Int) -> Bool) -> Int {
        guard start < end, predicate(start) else { return start }
        var lower = start + 1
        var step = 1
        while start + step < end && predicate(start + step) {
            lower = start + step + 1
            step *= 2
        }
        var upper = min(end, start + step)
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if predicate(middle) { lower = middle + 1 }
            else { upper = middle }
        }
        return lower
    }
}
