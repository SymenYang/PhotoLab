import Compression
import CryptoKit
import Foundation

/// Camera profiles in Adobe's formats, made up for tests and the regression suite, since Adobe's
/// own files are never committed (DEC-85): a `.dcp` written as TIFF tags, and an XMP look whose
/// tables are in Adobe's big-table encoding (TON-51, TON-52).
@_spi(Harness) public enum SyntheticCameraProfiles {
    /// A table over hue, saturation and value: a DCP's HueSatMap or LookTable, or an XMP look's.
    public struct HSVTable: Sendable {
        public var hues: Int
        public var saturations: Int
        public var values: Int
        /// Hue shift in degrees, saturation scale and value scale per point: value-major, then
        /// hue, then saturation.
        public var entries: [Float]
        public var srgbValues: Bool
        /// An XMP look's table version, 1 or 2; version 2 stores `amounts`.
        public var version: Int
        public var amounts: ClosedRange<Double>

        public init(
            hues: Int, saturations: Int, values: Int, entries: [Float], srgbValues: Bool = false, version: Int = 1,
            amounts: ClosedRange<Double> = 0 ... 2,
        ) {
            self.hues = hues
            self.saturations = saturations
            self.values = values
            self.entries = entries
            self.srgbValues = srgbValues
            self.version = version
            self.amounts = amounts
        }

        /// The same shift at every point.
        public static func uniform(
            hues: Int = 6, saturations: Int = 2, values: Int = 1, shift: SIMD3<Float>, version: Int = 1,
            amounts: ClosedRange<Double> = 0 ... 2,
        ) -> HSVTable {
            let count = hues * saturations * values
            return HSVTable(
                hues: hues, saturations: saturations, values: values,
                entries: (0 ..< count).flatMap { _ in [shift.x, shift.y, shift.z] }, version: version, amounts: amounts,
            )
        }
    }

    /// An Adobe RGB table: a curve per channel (1D) or a grid (3D).
    public struct RGBTable: Sendable {
        public var threeDimensional: Bool
        public var divisions: Int
        /// Output per sample in 0...1: each division's for 1D; for 3D red outermost, then green, then blue.
        public var samples: [SIMD3<Float>]
        /// 0 sRGB, 1 Adobe RGB, 2 ProPhoto.
        public var primaries: Int
        /// 0 linear, 1 sRGB, 2 gamma 1.8, 3 gamma 2.2.
        public var encoding: Int
        public var extendsGamut: Bool
        public var amounts: ClosedRange<Double>

        public init(
            threeDimensional: Bool, divisions: Int, samples: [SIMD3<Float>], primaries: Int = 0, encoding: Int = 1,
            extendsGamut: Bool = false, amounts: ClosedRange<Double> = 0 ... 2,
        ) {
            self.threeDimensional = threeDimensional
            self.divisions = divisions
            self.samples = samples
            self.primaries = primaries
            self.encoding = encoding
            self.extendsGamut = extendsGamut
            self.amounts = amounts
        }

        /// A 3D table sampling `transform` over its encoded inputs.
        public static func grid(
            divisions: Int, primaries: Int = 0, encoding: Int = 1, amounts: ClosedRange<Double> = 0 ... 2,
            transform: (SIMD3<Float>) -> SIMD3<Float>,
        ) -> RGBTable {
            let n = divisions
            var samples: [SIMD3<Float>] = []
            for r in 0 ..< n {
                for g in 0 ..< n {
                    for b in 0 ..< n {
                        samples.append(transform(SIMD3(Float(r), Float(g), Float(b)) / Float(n - 1)))
                    }
                }
            }
            return RGBTable(
                threeDimensional: true, divisions: n, samples: samples, primaries: primaries, encoding: encoding,
                amounts: amounts,
            )
        }
    }

    // MARK: - DCP

    /// A little-endian `.dcp` with the tags given. Matrices are row-major 3 x 3, written as
    /// rationals over 10,000.
    public static func dcp(
        name: String, camera: String, embedPolicy: Int = 0, copyright: String = "Synthetic test profile",
        colorMatrices: [[Double]], illuminants: [Int] = [17, 21], forwardMatrices: [[Double]] = [],
        hueSatMaps: [HSVTable] = [], lookTable: HSVTable? = nil, toneCurve: [SIMD2<Float>]? = nil,
        baselineExposureOffset: Double? = nil,
    ) -> Data {
        var tags: [(tag: UInt16, type: UInt16, count: Int, bytes: Data)] = []
        func ascii(_ tag: UInt16, _ text: String) {
            let bytes = Data(text.utf8) + [0]
            tags.append((tag, 2, bytes.count, bytes))
        }
        func longs(_ tag: UInt16, _ values: [Int]) {
            tags.append((tag, 4, values.count, values.reduce(into: Data()) { $0.append(little: UInt32($1)) }))
        }
        func shorts(_ tag: UInt16, _ values: [Int]) {
            tags.append((tag, 3, values.count, values.reduce(into: Data()) { $0.append(little: UInt16($1)) }))
        }
        func floats(_ tag: UInt16, _ values: [Float]) {
            tags.append((tag, 11, values.count, values.reduce(into: Data()) { $0.append(little: $1.bitPattern) }))
        }
        func rationals(_ tag: UInt16, _ values: [Double]) {
            tags.append((tag, 10, values.count, values.reduce(into: Data()) { data, value in
                data.append(little: UInt32(bitPattern: Int32((value * 10000).rounded())))
                data.append(little: UInt32(10000))
            }))
        }
        ascii(0xC614, camera)
        for (index, matrix) in colorMatrices.prefix(2).enumerated() {
            rationals(0xC621 + UInt16(index), matrix)
            shorts(0xC65A + UInt16(index), [illuminants[index]])
        }
        for (index, matrix) in forwardMatrices.prefix(2).enumerated() {
            rationals(0xC714 + UInt16(index), matrix)
        }
        ascii(0xC6F8, name)
        if let first = hueSatMaps.first {
            longs(0xC6F9, [first.hues, first.saturations, first.values])
            for (index, map) in hueSatMaps.prefix(2).enumerated() {
                floats(0xC6FA + UInt16(index), map.entries)
            }
            longs(0xC7A3, [first.srgbValues ? 1 : 0])
        }
        if let toneCurve {
            floats(0xC6FC, toneCurve.flatMap { [$0.x, $0.y] })
        }
        longs(0xC6FD, [embedPolicy])
        ascii(0xC6FE, copyright)
        if let lookTable {
            longs(0xC725, [lookTable.hues, lookTable.saturations, lookTable.values])
            floats(0xC726, lookTable.entries)
            longs(0xC7A4, [lookTable.srgbValues ? 1 : 0])
        }
        if let baselineExposureOffset {
            rationals(0xC7A5, [baselineExposureOffset])
        }
        tags.sort { $0.tag < $1.tag }

        var file = Data("IIRC".utf8)
        file.append(little: UInt32(8))
        var payload = Data()
        let payloadStart = 8 + 2 + tags.count * 12 + 4
        file.append(little: UInt16(tags.count))
        for tag in tags {
            file.append(little: tag.tag)
            file.append(little: tag.type)
            file.append(little: UInt32(tag.count))
            if tag.bytes.count <= 4 {
                file.append(tag.bytes + Data(count: 4 - tag.bytes.count))
            } else {
                file.append(little: UInt32(payloadStart + payload.count))
                payload.append(tag.bytes)
                if payload.count % 2 == 1 {
                    payload.append(0)
                }
            }
        }
        file.append(little: UInt32(0))
        return file + payload
    }

    // MARK: - XMP looks

    /// An XMP look profile as Camera Raw writes one. `toneCurve` is in 0...255; `settings` are
    /// further `crs:` attributes; `omittingTables` names the tables without including them, as
    /// Fujifilm's camera-matching looks do.
    public static func xmpLook(
        name: String, baseProfile: String? = "Adobe Standard", group: String? = nil, cluster: String? = "Adobe",
        camera: String? = nil, supportsAmount: Bool = false, grayscale: Bool = false, lookTable: HSVTable? = nil,
        rgbTable: RGBTable? = nil, rgbTableAmount: Double? = nil, toneCurve: [SIMD2<Float>]? = nil,
        settings: [String: String] = [:], requiresRGBTables: Bool = false, omittingTables: Bool = false,
    ) -> Data {
        var attributes: [(String, String)] = [
            ("PresetType", "Look"), ("UUID", Insecure.MD5.hash(data: Data(name.utf8)).hex.uppercased()),
            ("SupportsAmount", supportsAmount ? "True" : "False"), ("SupportsColor", grayscale ? "False" : "True"),
            ("SupportsMonochrome", grayscale ? "True" : "False"), (
                "RequiresRGBTables",
                requiresRGBTables ? "True" : "False",
            ),
            ("Copyright", "Synthetic test profile"), ("Version", "14.0"), ("ProcessVersion", "11.0"),
            ("ConvertToGrayscale", grayscale ? "True" : "False"), ("HasSettings", "True"),
        ]
        if let cluster {
            attributes.append(("Cluster", cluster))
        }
        if let baseProfile {
            attributes.append(("CameraProfile", baseProfile))
        }
        if let camera {
            attributes.append(("CameraModelRestriction", camera))
        }
        func table(_ key: String, _ bytes: Data) {
            let encoded = bigTable(bytes)
            let id = Insecure.MD5.hash(data: Data(encoded.utf8)).hex.uppercased()
            attributes.append((key, id))
            if !omittingTables {
                attributes.append(("Table_\(id)", encoded))
            }
        }
        if let lookTable {
            table("LookTable", hsvTableBytes(lookTable))
        }
        if let rgbTable {
            table("RGBTable", rgbTableBytes(rgbTable))
        }
        if let rgbTableAmount {
            attributes.append(("RGBTableAmount", String(rgbTableAmount)))
        }
        attributes += settings.sorted { $0.key < $1.key }
        var xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"

        """
        for (key, value) in attributes {
            xml += "    crs:\(key)=\"\(escaped(value))\"\n"
        }
        xml += "   >\n"
        xml += "   <crs:Name><rdf:Alt><rdf:li xml:lang=\"x-default\">\(escaped(name))</rdf:li></rdf:Alt></crs:Name>\n"
        if let group {
            xml += "   <crs:Group><rdf:Alt><rdf:li xml:lang=\"x-default\">\(escaped(group))</rdf:li></rdf:Alt></crs:Group>\n"
        }
        if let toneCurve {
            xml += "   <crs:ToneCurvePV2012><rdf:Seq>"
            xml += toneCurve.map { "<rdf:li>\(Int($0.x.rounded())), \(Int($0.y.rounded()))</rdf:li>" }.joined()
            xml += "</rdf:Seq></crs:ToneCurvePV2012>\n"
        }
        xml += "  </rdf:Description>\n </rdf:RDF>\n</x:xmpmeta>\n"
        return Data(xml.utf8)
    }

    /// Bytes in Adobe's big-table encoding: their length and a zlib stream, in base 85.
    public static func bigTable(_ bytes: Data) -> String {
        var stream = Data()
        stream.append(little: UInt32(bytes.count))
        stream.append(contentsOf: [0x78, 0x9C])
        let capacity = bytes.count * 2 + 64
        var deflated = Data(count: capacity)
        let written = deflated.withUnsafeMutableBytes { destination in
            bytes.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, bytes.count, nil, COMPRESSION_ZLIB,
                )
            }
        }
        stream.append(deflated.prefix(written))
        let checksum = adler32(bytes)
        stream.append(contentsOf: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: checksum >> $0) })
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?`'|()[]{}@%$#")
        var text = ""
        var index = 0
        while index < stream.count {
            let chunk = stream[stream.startIndex + index ..< stream.startIndex + min(index + 4, stream.count)]
            var value: UInt32 = 0
            for (shift, byte) in chunk.enumerated() {
                value |= UInt32(byte) << (8 * UInt32(shift))
            }
            for _ in 0 ... chunk.count {
                text.append(alphabet[Int(value % 85)])
                value /= 85
            }
            index += 4
        }
        return text
    }

    /// The DNG SDK's HSV big table: kind 0, its version and divisions, the points, the encoding
    /// and, in version 2, its amounts.
    public static func hsvTableBytes(_ table: HSVTable) -> Data {
        var data = Data()
        for word in [0, table.version, table.hues, table.saturations, table.values] {
            data.append(little: UInt32(word))
        }
        for entry in table.entries {
            data.append(little: entry.bitPattern)
        }
        data.append(little: UInt32(table.srgbValues ? 1 : 0))
        if table.version == 2 {
            data.append(little: table.amounts.lowerBound.bitPattern)
            data.append(little: table.amounts.upperBound.bitPattern)
        }
        return data
    }

    /// The DNG SDK's RGB table: kind 1, version 1, its dimensions and divisions, each sample as
    /// 16-bit differences from the identity, then its primaries, encoding, gamut and amounts.
    public static func rgbTableBytes(_ table: RGBTable) -> Data {
        let n = table.divisions
        var data = Data()
        for word in [1, 1, table.threeDimensional ? 3 : 1, n] {
            data.append(little: UInt32(word))
        }
        func grid(_ index: Int) -> UInt16 {
            UInt16((index * 0xFFFF + (n - 1) / 2) / (n - 1))
        }
        for (sample, value) in table.samples.enumerated() {
            let index = table.threeDimensional ? [sample / (n * n), sample / n % n, sample % n] : [
                sample,
                sample,
                sample,
            ]
            for channel in 0 ..< 3 {
                let level = UInt16((min(max(value[channel], 0), 1) * 65535).rounded())
                data.append(little: level &- grid(index[channel]))
            }
        }
        for word in [table.primaries, table.encoding, table.extendsGamut ? 1 : 0] {
            data.append(little: UInt32(word))
        }
        data.append(little: table.amounts.lowerBound.bitPattern)
        data.append(little: table.amounts.upperBound.bitPattern)
        return data
    }

    private static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return b << 16 | a
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private extension Data {
    mutating func append(little value: some FixedWidthInteger) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

private extension Insecure.MD5.Digest {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
