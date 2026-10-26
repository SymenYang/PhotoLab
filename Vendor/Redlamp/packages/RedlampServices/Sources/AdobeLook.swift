import Foundation

/// An Adobe XMP profile's look, as Camera Raw stores Adobe Color and the other Adobe Raw looks,
/// the creative looks and some camera-matching profiles: tables and a curve applied over a camera
/// profile, its base (TON-52). Read from the photographer's own files, never shipped (DEC-85).
public struct AdobeLook: Sendable, Hashable {
    /// A look table over hue, saturation and value, as a DCP's LookTable, with the strengths it may
    /// be applied at.
    public struct HSVTable: Sendable, Hashable {
        public var map: DNGProfile.HSVMap
        /// 1 or 2. A version 1 table stays at full strength at any Profile Amount.
        public var version: Int
        /// The strengths a version 2 table may be applied at; 1...1 for version 1.
        public var amounts: ClosedRange<Double>
    }

    public var name: String
    /// Lightroom's group for it, such as Artistic or B&W.
    public var group: String?
    /// Whose it is: Adobe's say Adobe.
    public var cluster: String?
    public var uuid: String?
    /// The camera profile it goes over (`crs:CameraProfile`), such as Adobe Standard; nil for a
    /// creative look, which goes over the camera's Adobe Standard.
    public var baseProfile: String?
    /// The camera it belongs to (`crs:CameraModelRestriction`); nil for any.
    public var camera: String?
    /// Whether Lightroom offers it a Profile Amount.
    public var supportsAmount: Bool
    public var convertsToGrayscale: Bool
    public var lookTable: HSVTable?
    public var rgbTable: AdobeRGBTable?
    /// `crs:RGBTableAmount`: how strongly the RGB table applies at a Profile Amount of 100.
    public var rgbTableAmount: Double
    /// `crs:ToneCurvePV2012`, inputs increasing, in 0...1 of sRGB-encoded values.
    public var toneCurve: [SIMD2<Float>]?
    /// The settings it carries that Redlamp leaves out, each as `Shadows +10`.
    public var leftOut: [String]
    public var copyright: String?

    public enum ReadError: Error, Equatable, CustomStringConvertible {
        case notXMP
        case notALook
        case needsPhotoTables
        case missingTable(String)
        case unreadableTable(String)
        case invalid(String)
        case nothingToRender

        public var description: String {
            switch self {
            case .notXMP: "isn't an XMP file"
            case .notALook: "is a preset, not a profile"
            case .needsPhotoTables: "needs the photo's own color tables, which only Camera Raw reads"
            case let .missingTable(name): "names a \(name) that isn't in the file"
            case let .unreadableTable(reason): "has a table Redlamp can't read: \(reason)"
            case let .invalid(reason): "isn't a profile Redlamp can read: \(reason)"
            case .nothingToRender: "has no table or curve Redlamp can render"
            }
        }
    }

    static let crs = "http://ns.adobe.com/camera-raw-settings/1.0/"

    /// Larger files aren't profiles.
    public static let largestFile = 24 << 20

    public init(xmp data: Data) throws(ReadError) {
        guard data.count <= Self.largestFile, let resources = LCPResource.read(data) else { throw .notXMP }
        guard let look = resources.first(where: { $0.value("PresetType", in: Self.crs) != nil }) else {
            throw .notALook
        }
        func text(_ name: String) -> String? {
            guard case let .literal(value)? = look.value(name, in: Self.crs) else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func flag(_ name: String) throws(ReadError) -> Bool? {
            guard let value = text(name) else { return nil }
            switch value.lowercased() {
            case "true": return true
            case "false": return false
            default: throw .invalid("\(name) is \(value)")
            }
        }
        func table(_ name: String) throws(ReadError) -> Data? {
            guard let id = text(name) else { return nil }
            guard let encoded = text("Table_\(id)")
            else { throw .missingTable(name == "RGBTable" ? "color table" : "look table") }
            do {
                return try AdobeTableEncoding.decode(encoded)
            } catch {
                throw .unreadableTable(error.description)
            }
        }
        guard text("PresetType") == "Look" else { throw .notALook }
        guard try flag("RequiresRGBTables") != true else { throw .needsPhotoTables }
        name = Self.firstText(look.value("Name", in: Self.crs)) ?? ""
        guard !name.isEmpty else { throw .invalid("it has no name") }
        group = Self.firstText(look.value("Group", in: Self.crs))
        cluster = text("Cluster")
        uuid = text("UUID")
        baseProfile = text("CameraProfile")
        camera = text("CameraModelRestriction")
        copyright = text("Copyright")
        supportsAmount = try flag("SupportsAmount") ?? false
        convertsToGrayscale = try flag("ConvertToGrayscale") ?? false
        lookTable = try table("LookTable").map(Self.hsvTable)
        rgbTable = try table("RGBTable").map(AdobeRGBTable.init(bytes:))
        rgbTableAmount = 1
        if let value = text("RGBTableAmount") {
            guard let amount = Double(value), amount.isFinite, (0 ... 2).contains(amount) else {
                throw .invalid("its RGBTableAmount is \(value)")
            }
            rgbTableAmount = amount
        }
        var leftOut: [String] = []
        toneCurve = nil
        for property in look.properties where property.namespace == Self.crs {
            let name = property.name
            if Self.metadata.contains(name) || name.hasPrefix("Table_") {
                continue
            }
            if name.hasPrefix("ToneCurvePV2012") {
                let points = try Self.curve(property.value, name: name)
                if name == "ToneCurvePV2012" {
                    toneCurve = Self.isIdentity(points) ? nil : points
                } else if !Self.isIdentity(points) {
                    leftOut.append(Self.words(name.replacingOccurrences(of: "ToneCurvePV2012", with: "")) + " curve")
                }
                continue
            }
            if case let .literal(value) = property.value {
                if !Self.isDefault(value) {
                    leftOut.append("\(Self.words(name)) \(value.trimmingCharacters(in: .whitespaces))")
                }
            } else {
                leftOut.append(Self.words(name))
            }
        }
        self.leftOut = leftOut
        guard lookTable != nil || rgbTable != nil || toneCurve != nil else { throw .nothingToRender }
        var identity = ProfileIdentity("look")
        identity.add(lookTable?.map)
        for value in [lookTable?.version ?? 0, supportsAmount ? 1 : 0, convertsToGrayscale ? 1 : 0] {
            identity.add(value)
        }
        identity.add([lookTable?.amounts.lowerBound ?? 0, lookTable?.amounts.upperBound ?? 0, rgbTableAmount])
        if let rgbTable {
            for value in [
                rgbTable.isThreeDimensional ? 3 : 1,
                rgbTable.divisions,
                rgbTable.primaries.rawValue,
                rgbTable.encoding.rawValue,
                rgbTable.extendsGamut ? 1 : 0,
            ] {
                identity.add(value)
            }
            identity.add(rgbTable.samples)
            identity.add([rgbTable.amounts.lowerBound, rgbTable.amounts.upperBound])
        } else {
            identity.add(0)
        }
        identity.add(toneCurve?.flatMap { [$0.x, $0.y] } ?? [])
        self.identity = identity.digest
    }

    /// 16 hex digits of a SHA-256 over what renders, so the same look is one look wherever its file is.
    public private(set) var identity = ""

    /// Properties that describe the look rather than set anything.
    private static let metadata: Set<String> = [
        "PresetType", "Cluster", "UUID", "SupportsAmount", "SupportsColor", "SupportsMonochrome",
        "SupportsHighDynamicRange", "SupportsNormalDynamicRange", "SupportsSceneReferred", "SupportsOutputReferred",
        "CameraModelRestriction", "Copyright", "ContactInfo", "Version", "ProcessVersion", "ConvertToGrayscale",
        "CameraProfile", "CameraProfileDigest", "LookTable", "RGBTable", "RGBTableAmount", "RequiresRGBTables",
        "ShowInPresets", "ShowInQuickActions", "HasSettings", "ToneCurveName2012", "Name", "ShortName", "SortName",
        "Group", "Description", "Amount",
    ]

    private static func firstText(_ value: LCPResource.Value?) -> String? {
        switch value {
        case let .literal(text)?:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let .list(items)?:
            return items.lazy.compactMap { firstText($0) }.first
        default:
            return nil
        }
    }

    /// `x, y` pairs in 0...255, inputs increasing.
    private static func curve(_ value: LCPResource.Value, name: String) throws(ReadError) -> [SIMD2<Float>] {
        guard case let .list(items) = value else { throw .invalid("\(name) isn't a list of points") }
        var points: [SIMD2<Float>] = []
        for item in items {
            guard case let .literal(text) = item else { throw .invalid("\(name) has a point that isn't text") }
            let parts = text.split(separator: ",").map { Float($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2, let x = parts[0], let y = parts[1], (0 ... 255).contains(x), (0 ... 255).contains(y)
            else { throw .invalid("\(name) has a point that isn't two numbers from 0 to 255") }
            points.append(SIMD2(x, y) / 255)
        }
        guard points.count >= 2, zip(points, points.dropFirst()).allSatisfy({ $0.x < $1.x }) else {
            throw .invalid("\(name) needs two points or more, left to right")
        }
        return points
    }

    private static func isIdentity(_ points: [SIMD2<Float>]) -> Bool {
        points.allSatisfy { abs($0.x - $0.y) < 1e-6 }
    }

    private static func isDefault(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let number = Double(trimmed) {
            return number == 0
        }
        return trimmed.isEmpty || trimmed.lowercased() == "false"
    }

    /// `SplitToningShadowHue` as `Split Toning Shadow Hue`, and `Shadows2012` as `Shadows`.
    private static func words(_ name: String) -> String {
        let trimmed = name.hasSuffix("2012") ? String(name.dropLast(4)) : name
        var result = ""
        for character in trimmed {
            if character.isUppercase, !result.isEmpty, result.last?.isUppercase == false {
                result.append(" ")
            }
            result.append(character)
        }
        return result
    }

    /// The DNG SDK's HSV big table: kind 0, version 1 or 2, hue, saturation and value divisions,
    /// three floats per point in the DCP's order, the value encoding, and in version 2 the
    /// strengths it may be applied at; some end with a flags word of zero.
    static func hsvTable(_ data: Data) throws(ReadError) -> HSVTable {
        let bytes = [UInt8](data)
        func word(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
        }
        func real(_ offset: Int) -> Double {
            Double(bitPattern: UInt64(word(offset)) | UInt64(word(offset + 4)) << 32)
        }
        guard bytes.count >= 24, word(0) == 0, (1 ... 2).contains(word(4)) else {
            throw .unreadableTable("it isn't a look table of a version Redlamp knows")
        }
        let version = Int(word(4))
        let dims = [Int(word(8)), Int(word(12)), Int(word(16))]
        guard dims.allSatisfy({ (1 ... 360).contains($0) }), dims[0] * dims[1] * dims[2] <= 1_000_000 else {
            throw .unreadableTable("its divisions are out of range")
        }
        let count = dims[0] * dims[1] * dims[2]
        let end = 20 + count * 12
        let tail = version == 2 ? 20 : 4
        guard bytes.count == end + tail || bytes.count == end + tail + 4 else {
            throw .unreadableTable("its size doesn't match its divisions")
        }
        guard word(end) <= 1 else { throw .unreadableTable("its value encoding is unknown") }
        if bytes.count == end + tail + 4, word(end + tail) != 0 {
            throw .unreadableTable("it has flags Redlamp doesn't know")
        }
        var amounts: ClosedRange<Double> = 1 ... 1
        if version == 2 {
            let (low, high) = (real(end + 4), real(end + 12))
            guard low.isFinite, high.isFinite, (0 ... 1).contains(low), high >= 1 else {
                throw .unreadableTable("its amounts are out of range")
            }
            amounts = low ... min(high, 2)
        }
        let entries = (0 ..< count * 3).map { Float(bitPattern: word(20 + $0 * 4)) }
        guard let map = DNGProfile.HSVMap(
            hues: dims[0], saturations: dims[1], values: dims[2], entries: entries, srgbValues: word(end) == 1,
        ) else { throw .unreadableTable("its divisions or points are out of range") }
        return HSVTable(map: map, version: version, amounts: amounts)
    }
}

/// An Adobe RGB table (the DNG SDK's `dng_rgb_table`), which creative looks and some camera-matching
/// looks carry: a curve per channel, or a grid over all three, in the table's own primaries and
/// encoding, applied at a strength (TON-52).
public struct AdobeRGBTable: Sendable, Hashable {
    public enum Primaries: Int, Sendable {
        case sRGB, adobeRGB, proPhoto
    }

    public enum Encoding: Int, Sendable {
        case linear, sRGB, gamma18, gamma22
    }

    public var isThreeDimensional: Bool
    public var divisions: Int
    /// Red, green and blue out per sample, in 0...1: each division's for a 1D table; for a 3D one,
    /// red outermost, then green, then blue.
    public var samples: [Float]
    public var primaries: Primaries
    public var encoding: Encoding
    /// Whether colours outside the table's space keep what clipping into it took away.
    public var extendsGamut: Bool
    /// The strengths it may be applied at.
    public var amounts: ClosedRange<Double>

    public init(
        isThreeDimensional: Bool, divisions: Int, samples: [Float], primaries: Primaries, encoding: Encoding,
        extendsGamut: Bool, amounts: ClosedRange<Double>,
    ) {
        self.isThreeDimensional = isThreeDimensional
        self.divisions = divisions
        self.samples = samples
        self.primaries = primaries
        self.encoding = encoding
        self.extendsGamut = extendsGamut
        self.amounts = amounts
    }

    /// Kind 1, version 1, its dimensions and divisions, three 16-bit differences from the identity
    /// per sample, then its primaries, encoding, gamut and amounts; Adobe's camera-matching tables
    /// add a word that renders the same at 0 and 1.
    init(bytes data: Data) throws(AdobeLook.ReadError) {
        let bytes = [UInt8](data)
        func word(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
        }
        func real(_ offset: Int) -> Double {
            Double(bitPattern: UInt64(word(offset)) | UInt64(word(offset + 4)) << 32)
        }
        guard bytes.count >= 16, word(0) == 1, word(4) == 1 else {
            throw .unreadableTable("it isn't a color table of a version Redlamp knows")
        }
        let divisions = Int(word(12))
        let count: Int
        switch word(8) {
        case 1:
            guard (2 ... 4096).contains(divisions) else { throw .unreadableTable("its divisions are out of range") }
            count = divisions
            isThreeDimensional = false
        case 3:
            guard (2 ... 64).contains(divisions) else { throw .unreadableTable("its divisions are out of range") }
            count = divisions * divisions * divisions
            isThreeDimensional = true
        default:
            throw .unreadableTable("it has \(word(8)) dimensions")
        }
        let end = 16 + count * 6
        guard bytes.count == end + 28 || bytes.count == end + 32 else {
            throw .unreadableTable("its size doesn't match its divisions")
        }
        if bytes.count == end + 32, word(end + 28) > 1 {
            throw .unreadableTable("it has flags Redlamp doesn't know")
        }
        guard let primaries = Primaries(rawValue: Int(word(end))), let encoding = Encoding(rawValue: Int(word(end + 4)))
        else { throw .unreadableTable("its primaries or encoding are unknown") }
        guard word(end + 8) <= 1 else { throw .unreadableTable("its gamut handling is unknown") }
        let (low, high) = (real(end + 12), real(end + 20))
        guard low.isFinite, high.isFinite, (0 ... 1).contains(low), (1 ... 4).contains(high) else {
            throw .unreadableTable("its amounts are out of range")
        }
        let n = divisions
        func grid(_ index: Int) -> UInt16 {
            UInt16((index * 0xFFFF + (n - 1) / 2) / (n - 1))
        }
        var samples = [Float](repeating: 0, count: count * 3)
        for sample in 0 ..< count {
            let index = isThreeDimensional ? [sample / (n * n), sample / n % n, sample % n] : [sample, sample, sample]
            for channel in 0 ..< 3 {
                let at = 16 + sample * 6 + channel * 2
                let delta = UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
                samples[sample * 3 + channel] = Float(delta &+ grid(index[channel])) / 65535
            }
        }
        self.divisions = divisions
        self.samples = samples
        self.primaries = primaries
        self.encoding = encoding
        extendsGamut = word(end + 8) == 1
        amounts = low ... min(high, 2)
    }
}
