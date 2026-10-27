import Foundation
import CryptoKit

/// Natural name order is index metadata, independent of query/category or
/// file size/time. Persist it so a new app session does not sort names again.
enum ResultNameRankCache {
    private static let magic = Array("FSNAMES1".utf8)
    private static let queue = DispatchQueue(label: "FSearch.name-sort-index", qos: .utility)

    static var defaultURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("cn.trah.fsearch.desktop", isDirectory: true)
            .appendingPathComponent("name-order-v1.bin")
    }

    private static var identity: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let collation = (Locale.current as NSLocale).object(forKey: .collatorIdentifier) as? String ?? ""
        return "\(version.majorVersion).\(version.minorVersion):\(Locale.current.identifier):\(collation)"
    }

    static func load(_ url: URL?) -> [Substring: UInt64] {
        guard let url, let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count >= 48, data.count <= 512 * 1024 * 1024 else { return [:] }
        let body = data.dropLast(32)
        guard data.suffix(32).elementsEqual(SHA256.hash(data: body)) else { return [:] }
        return body.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard bytes.prefix(8).elementsEqual(magic) else { return [:] }
            let identityLength = Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self)))
            let count = Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 12, as: UInt32.self)))
            guard identityLength <= bytes.count - 16, count <= (bytes.count - 16 - identityLength) / 12,
                  String(decoding: bytes[16..<(16 + identityLength)], as: UTF8.self) == identity else { return [:] }
            var values: [Substring: UInt64] = [:]
            values.reserveCapacity(count)
            var offset = 16 + identityLength
            for _ in 0..<count {
                guard offset <= bytes.count - 12 else { return [:] }
                let length = Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                let rank = UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 4, as: UInt64.self))
                offset += 12
                guard length <= bytes.count - offset, rank < UInt64(count) else { return [:] }
                let name = String(decoding: bytes[offset..<(offset + length)], as: UTF8.self)
                values[Substring(name)] = rank
                offset += length
            }
            guard offset == bytes.count, values.count == count else { return [:] }
            return values
        }
    }

    static func save(_ values: [Substring: UInt64], to url: URL?) {
        guard let url else { return }
        let locale = identity
        queue.async {
            var data = Data(magic)
            let localeBytes = Array(locale.utf8)
            append(UInt32(localeBytes.count), to: &data)
            append(UInt32(values.count), to: &data)
            data.append(contentsOf: localeBytes)
            for (name, rank) in values {
                append(UInt32(name.utf8.count), to: &data)
                append(rank, to: &data)
                data.append(contentsOf: name.utf8)
            }
            data.append(contentsOf: SHA256.hash(data: data))
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch { /* A cache write must never prevent searching or sorting. */ }
        }
    }

    /// Used by targeted benchmarks to include completion of the cache write.
    static func flush() { queue.sync {} }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}
