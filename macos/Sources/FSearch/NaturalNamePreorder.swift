import Foundation

/// Cheap natural-key radix preordering gives the adaptive localized sort long
/// ordered runs. This is only a preprocessing step: Foundation's actual
/// localizedStandardCompare still decides every final name rank.
enum NaturalNamePreorder {
    static func sorted(_ names: [NSString], cancellation: ResultSortCancellation) throws -> [UInt32] {
        var rows = (0..<names.count).map { UInt32($0) }
        guard names.count > 4096 else { return rows }
        var keys: [UInt8] = []
        var offsets: [Int] = []
        offsets.reserveCapacity(names.count + 1)
        for (index, name) in names.enumerated() {
            if index & 4095 == 0 { try cancellation.check() }
            offsets.append(keys.count)
            let text = name as String
            let bytes: [UInt8]
            if text.utf8.allSatisfy({ $0 < 128 }) { bytes = Array(text.utf8) }
            else {
                bytes = Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current).utf8)
            }
            var position = 0
            while position < bytes.count {
                let byte = bytes[position]
                if byte >= 48 && byte <= 57 {
                    var end = position + 1
                    while end < bytes.count && bytes[end] >= 48 && bytes[end] <= 57 { end += 1 }
                    var significant = position
                    while significant < end - 1 && bytes[significant] == 48 { significant += 1 }
                    let length = UInt32(end - significant)
                    keys.append(48)
                    for shift in stride(from: 24, through: 0, by: -8) { keys.append(UInt8((length >> shift) & 255)) }
                    keys.append(contentsOf: bytes[significant..<end])
                    position = end
                } else {
                    keys.append(byte >= 65 && byte <= 90 ? byte + 32 : byte)
                    position += 1
                }
            }
        }
        offsets.append(keys.count)
        var scratch = [UInt32](repeating: 0, count: rows.count)
        var work = [(lower: 0, upper: rows.count, depth: 0)]
        while let range = work.popLast() {
            try cancellation.check()
            if range.upper - range.lower <= 24 {
                // Tiny buckets use insertion sort, skipping the common prefix.
                for position in (range.lower + 1)..<range.upper {
                    let row = rows[position]
                    var previous = position
                    while previous > range.lower && less(row, rows[previous - 1], depth: range.depth, keys: keys, offsets: offsets) {
                        rows[previous] = rows[previous - 1]
                        previous -= 1
                    }
                    rows[previous] = row
                }
                continue
            }
            // Bucket zero is the end of a key; bytes occupy buckets 1...256.
            var counts = [Int](repeating: 0, count: 257)
            for position in range.lower..<range.upper {
                if position & 16383 == 0 { try cancellation.check() }
                let row = Int(rows[position])
                let offset = offsets[row] + range.depth
                let bucket = offset < offsets[row + 1] ? Int(keys[offset]) + 1 : 0
                counts[bucket] += 1
            }
            if let bucket = counts.firstIndex(of: range.upper - range.lower) {
                if bucket != 0 { work.append((range.lower, range.upper, range.depth + 1)) }
                continue
            }
            var starts = [Int](repeating: range.lower, count: 257)
            var end = range.lower
            for bucket in counts.indices {
                starts[bucket] = end
                end += counts[bucket]
            }
            var next = starts
            for position in range.lower..<range.upper {
                if position & 16383 == 0 { try cancellation.check() }
                let row = Int(rows[position])
                let offset = offsets[row] + range.depth
                let bucket = offset < offsets[row + 1] ? Int(keys[offset]) + 1 : 0
                scratch[next[bucket]] = rows[position]
                next[bucket] += 1
            }
            for position in range.lower..<range.upper { rows[position] = scratch[position] }
            for bucket in 1..<257 where counts[bucket] > 1 {
                work.append((starts[bucket], starts[bucket] + counts[bucket], range.depth + 1))
            }
        }
        return rows
    }

    private static func less(_ a: UInt32, _ b: UInt32, depth: Int, keys: [UInt8], offsets: [Int]) -> Bool {
        var left = offsets[Int(a)] + depth
        var right = offsets[Int(b)] + depth
        let leftEnd = offsets[Int(a) + 1], rightEnd = offsets[Int(b) + 1]
        while left < leftEnd && right < rightEnd {
            if keys[left] != keys[right] { return keys[left] < keys[right] }
            left += 1
            right += 1
        }
        return left == leftEnd && right != rightEnd
    }
}
