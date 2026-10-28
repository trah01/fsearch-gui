import Foundation

enum SearchBinaryRows {
    static func decode(_ data: Data, count: Int) throws -> [SearchHit] {
        guard count >= 0, count <= data.count / 20 else { throw invalidResponse }
        return try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var rows: [SearchHit] = []
            rows.reserveCapacity(count)
            var offset = 0
            for index in 0..<count {
                if index % 1024 == 0 { try Task.checkCancellation() }
                guard offset <= bytes.count - 20 else { throw invalidResponse }
                let length = Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                let kind = bytes[offset + 4]
                let mask = bytes[offset + 5]
                let size = UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 8, as: UInt64.self))
                let modified = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 16, as: UInt32.self))
                offset += 20
                guard length <= bytes.count - offset, size <= Int64.max, kind <= 3 else { throw invalidResponse }
                let path = String(decoding: bytes[offset..<(offset + length)], as: UTF8.self)
                rows.append(SearchHit(path: path, kind: kind, size: Int64(size),
                    modified: Date(timeIntervalSince1970: Double(modified)), typeMask: mask))
                offset += length
            }
            guard offset == bytes.count else { throw invalidResponse }
            return rows
        }
    }

    private static var invalidResponse: ClientError { .message(L("搜索服务返回了无法识别的数据。")) }
}
