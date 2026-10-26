import Compression
import Foundation

/// The encoding Camera Raw's XMP profiles store their tables in (`crs:Table_<md5>`, the DNG SDK's
/// big tables): base 85 in Adobe's alphabet, least significant digit first, each five digits four
/// bytes and a shorter last group one byte fewer than its digits, over the table's expanded length
/// (four bytes, little-endian) and a zlib stream (TON-52).
enum AdobeTableEncoding {
    static let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?`'|()[]{}@%$#"
        .utf8)

    /// Longer text isn't a profile's table.
    static let largestText = 16 << 20
    /// A 64-division 3D RGB table, the largest a profile holds, expands to about 1.6 MB.
    static let largestTable = 12 << 20

    enum DecodeError: Error, Equatable, CustomStringConvertible {
        case tooLarge
        case invalidDigit
        case truncated
        case invalidStream

        var description: String {
            switch self {
            case .tooLarge: "the table is larger than a profile's"
            case .invalidDigit: "the table has a character Adobe's encoding doesn't use"
            case .truncated: "the table is cut short"
            case .invalidStream: "the table's compressed data is damaged"
            }
        }
    }

    private static let digitValues: [UInt8: UInt32] = Dictionary(
        uniqueKeysWithValues: alphabet.enumerated().map { ($1, UInt32($0)) },
    )

    /// The table's bytes.
    static func decode(_ text: String) throws(DecodeError) -> Data {
        guard text.utf8.count <= largestText else { throw .tooLarge }
        let digits = text.utf8.filter { !($0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D) }
        guard digits.count % 5 != 1 else { throw .truncated }
        var bytes = [UInt8]()
        bytes.reserveCapacity(digits.count / 5 * 4 + 4)
        var index = 0
        while index < digits.count {
            let group = digits[index ..< min(index + 5, digits.count)]
            var value: UInt64 = 0
            var power: UInt64 = 1
            for digit in group {
                guard let number = digitValues[digit] else { throw .invalidDigit }
                value += UInt64(number) * power
                power *= 85
            }
            guard value <= UInt64(UInt32.max) else { throw .invalidDigit }
            for shift in 0 ..< group.count - 1 {
                bytes.append(UInt8(truncatingIfNeeded: value >> (8 * UInt64(shift))))
            }
            index += 5
        }
        guard bytes.count >= 4 + 2 + 4 else { throw .truncated }
        let expected = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        guard expected > 0, expected <= largestTable else { throw .tooLarge }
        return try inflate(bytes[4...], expected: expected)
    }

    /// A zlib stream (RFC 1950) into exactly `expected` bytes, its checksum checked.
    private static func inflate(_ stream: ArraySlice<UInt8>, expected: Int) throws(DecodeError) -> Data {
        let start = stream.startIndex
        let header = (Int(stream[start]) << 8) | Int(stream[start + 1])
        // Deflate, no preset dictionary, and the header's own check.
        guard stream[start] & 0x0F == 8, stream[start + 1] & 0x20 == 0, header % 31 == 0, stream.count >= 6 else {
            throw .invalidStream
        }
        var output = Data(count: expected + 1)
        let written = output.withUnsafeMutableBytes { destination in
            stream.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, expected + 1,
                    source.bindMemory(to: UInt8.self).baseAddress! + 2, stream.count - 2, nil, COMPRESSION_ZLIB,
                )
            }
        }
        guard written == expected else { throw .invalidStream }
        output.count = expected
        let end = stream.endIndex
        let stored = UInt32(stream[end - 4]) << 24 | UInt32(stream[end - 3]) << 16 | UInt32(stream[end - 2]) << 8
            | UInt32(stream[end - 1])
        guard adler32(output) == stored else { throw .invalidStream }
        return output
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        data.withUnsafeBytes { bytes in
            var index = 0
            while index < bytes.count {
                // 5552 bytes keep the sums inside 32 bits before the modulo.
                let end = min(index + 5552, bytes.count)
                for byte in bytes[index ..< end] {
                    a += UInt32(byte)
                    b += a
                }
                a %= 65521
                b %= 65521
                index = end
            }
        }
        return b << 16 | a
    }
}
