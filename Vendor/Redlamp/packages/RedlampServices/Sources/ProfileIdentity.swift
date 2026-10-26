import CryptoKit
import Foundation

/// A camera profile's identity: 16 hex digits of a SHA-256 over what renders, fed in a fixed
/// order as little-endian bytes, so the same profile is one profile on every Mac (TON-51, TON-52).
struct ProfileIdentity {
    private var hash = SHA256()

    init(_ kind: String) {
        add(kind)
    }

    mutating func add(_ text: String) {
        add(text.utf8.count)
        hash.update(data: Data(text.utf8))
    }

    mutating func add(_ value: Int) {
        withUnsafeBytes(of: Int64(value).littleEndian) { hash.update(bufferPointer: $0) }
    }

    mutating func add(_ value: Double) {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { hash.update(bufferPointer: $0) }
    }

    /// In memory order, which on every Mac is little-endian.
    mutating func add(_ values: [Float]) {
        add(values.count)
        values.withUnsafeBytes { hash.update(bufferPointer: $0) }
    }

    mutating func add(_ values: [Double]) {
        add(values.count)
        values.withUnsafeBytes { hash.update(bufferPointer: $0) }
    }

    mutating func add(_ map: DNGProfile.HSVMap?) {
        guard let map else { return add(0) }
        for value in [1, map.hues, map.saturations, map.values, map.srgbValues ? 1 : 0] {
            add(value)
        }
        add(map.entries)
    }

    var digest: String {
        hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
