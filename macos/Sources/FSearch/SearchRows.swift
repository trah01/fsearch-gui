import Foundation

/// A virtual row collection: changing order shares the original records and
/// only swaps a compact permutation. NSTableView reads actual hits on demand.
struct SearchRows: RandomAccessCollection, Sendable {
    typealias Index = Int
    private let base: [SearchHit]
    private let order: [UInt32]?

    init(_ base: [SearchHit] = [], order: [UInt32]? = nil) {
        self.base = base
        self.order = order
    }

    var startIndex: Int { 0 }
    var endIndex: Int { order?.count ?? base.count }
    subscript(position: Int) -> SearchHit { base[order.map { Int($0[position]) } ?? position] }

    func reordered(by indices: [UInt32]) -> SearchRows {
        guard let order else { return SearchRows(base, order: indices) }
        return SearchRows(base, order: indices.map { order[Int($0)] })
    }
}
