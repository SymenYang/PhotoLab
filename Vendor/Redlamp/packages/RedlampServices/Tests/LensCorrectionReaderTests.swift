import Foundation
import RedlampEngineAPI
import simd
import Testing
@testable import RedlampServices

/// The lens corrections raw files carry (LNS-02).
struct LensCorrectionReaderTests {
    private static func fixture(_ prefix: String) -> URL? {
        DecodeRegressionTests.fixtures.first { $0.lastPathComponent.hasPrefix(prefix) }
    }

    private static func read(_ url: URL) throws -> LensCorrection? {
        try LensCorrectionReader.read(Data(contentsOf: url), url: url, orientation: 0)
    }

    @Test(.enabled(if: fixture("PXL_") != nil))
    func `the Pixel's identity warp is no correction`() throws {
        let url = try #require(Self.fixture("PXL_"))
        #expect(try Self.read(url) == nil)
    }

    @Test func `reads DNG warp and vignetting opcodes`() throws {
        let data = Self.dng(opcodes: Self.warp([1, -0.05, 0.01, 0], center: [0.4, 0.5]) + Self.vignette([
            0.3,
            0.1,
            0,
            0,
            0,
        ]))
        let lens = try #require(LensCorrectionReader.read(
            data,
            url: URL(fileURLWithPath: "/tmp/t.dng"),
            orientation: 0,
        ))
        #expect(lens.source == .dng && lens.center == SIMD2(0.4, 0.5))
        for r in [0.0, 0.3, 0.7, 1.0] {
            let expected = 1 - 0.05 * r * r + 0.01 * pow(r, 4)
            #expect(abs(lens.interpolate(lens.distortion, at: r).y - expected) < 2e-4, "f(\(r))")
            #expect(
                abs(lens.interpolate(lens.vignetting, at: r) - (1 + 0.3 * r * r + 0.1 * pow(r, 4))) < 2e-3,
                "g(\(r))",
            )
        }
        // A photo turned a quarter: the centre turns with it.
        let turned = try #require(LensCorrectionReader.read(
            data,
            url: URL(fileURLWithPath: "/tmp/t.dng"),
            orientation: 6,
        ))
        #expect(turned.center == SIMD2(0.5, 0.4))
    }

    @Test func `a vignetting opcode whose gains aren't numbers is left out`() throws {
        for k in [[Double.nan, 0, 0, 0, 0], [1e308, 1e308, 0, 0, 0]] {
            let lens = try #require(LensCorrectionReader.read(
                Self.dng(opcodes: Self.warp([1, -0.05, 0, 0], center: [0.5, 0.5]) + Self.vignette(k)),
                url: URL(fileURLWithPath: "/tmp/t.dng"),
                orientation: 0,
            ))
            #expect(lens.vignetting.isEmpty && !lens.distortion.isEmpty && lens.isValid, "\(k)")
        }
    }

    /// One WarpRectilinear opcode, big-endian: one coefficient set, no tangential terms.
    private static func warp(_ k: [Double], center: [Double]) -> Data {
        var parameters = Data()
        parameters.append(be: UInt32(1))
        for value in k + [0, 0] + center {
            parameters.append(be: value.bitPattern)
        }
        return opcode(id: 1, parameters)
    }

    private static func vignette(_ k: [Double]) -> Data {
        var parameters = Data()
        for value in k + [0.5, 0.5] {
            parameters.append(be: value.bitPattern)
        }
        return opcode(id: 3, parameters)
    }

    private static func opcode(id: UInt32, _ parameters: Data) -> Data {
        var data = Data()
        data.append(be: id)
        data.append(contentsOf: [1, 3, 0, 0])
        data.append(be: UInt32(1))
        data.append(be: UInt32(parameters.count))
        return data + parameters
    }

    /// A little-endian TIFF whose only tag is OpcodeList3.
    private static func dng(opcodes: Data) -> Data {
        var list = Data()
        list.append(be: UInt32(opcodes.isEmpty ? 0 : 2))
        list += opcodes
        var data = Data("II".utf8)
        func append(_ value: some FixedWidthInteger) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(UInt16(42))
        append(UInt32(8))
        append(UInt16(1))
        append(UInt16(0xC74E))
        append(UInt16(7))
        append(UInt32(list.count))
        append(UInt32(8 + 2 + 12 + 4))
        append(UInt32(0))
        return data + list
    }

    @Test(.enabled(if: fixture("_DSC0009") != nil))
    func `reads Sony's correction tags`() throws {
        let url = try #require(Self.fixture("_DSC0009"))
        let lens = try #require(try Self.read(url))
        #expect(lens.source == .sony && lens.radii.count == 16)
        #expect(lens.distortion.allSatisfy { abs($0.y - 1) < 0.1 }, "distortion \(lens.distortion.map(\.y))")
        #expect(lens.vignetting.allSatisfy { $0 >= 0.99 && $0 < 4 }, "vignetting gains \(lens.vignetting)")
        #expect(try #require(lens.vignetting.last) > lens.vignetting.first!, "the corners need more light")
    }

    @Test(.enabled(if: fixture("AFXT2720") != nil))
    func `reads Fujifilm's correction tags`() throws {
        let url = try #require(Self.fixture("AFXT2720"))
        let lens = try #require(try Self.read(url))
        #expect(lens.source == .fujifilm && lens.radii.count == 9)
        #expect(abs(lens.radii[0] - 0.3535) < 1e-3 && abs(lens.radii[8] - 1.0606) < 1e-3)
        // A wide kit zoom's barrel: the corners recorded about 9% in.
        #expect(abs(lens.distortion[8].y - 0.911) < 2e-3, "\(lens.distortion.map(\.y))")
        // Red recorded a little inside green and blue a little outside, as measured from the photo.
        #expect(lens.distortion.allSatisfy { $0.x < $0.y && $0.z > $0.y })
        #expect(lens.vignetting.allSatisfy { abs($0 - 1) < 1e-9 }, "no vignetting correction on this lens")
    }

    @Test func `files without corrections have none`() throws {
        for prefix in ["DSC_0750", "IMG_1361"] {
            guard let url = Self.fixture(prefix) else { continue }
            #expect(try Self.read(url) == nil, "\(prefix)")
        }
    }

    private static func camera(_ prefix: String) -> URL? {
        DecodeRegressionTests.cameras.first { $0.lastPathComponent.hasPrefix(prefix) }
    }

    @Test(.enabled(if: camera("Panasonic_DC-S5M2") != nil))
    func `reads Panasonic's distortion tag`() throws {
        let url = try #require(Self.camera("Panasonic_DC-S5M2"))
        let lens = try #require(ImageDecoder.decode(url).lensCorrection)
        #expect(lens.source == .panasonic && lens.center == SIMD2(0.5, 0.5) && lens.vignetting.isEmpty)
        // The camera's JPEG is the recorded frame enlarged by 1/(1 − 167·2⁻¹⁵), with a wave of
        // ±0.1% across it.
        for (radius, expected) in [(0.0, 0.994904), (0.5, 0.993190), (1.0, 1.000039)] {
            let scale = lens.interpolate(lens.distortion, at: radius)
            #expect(abs(scale.y - expected) < 2e-5 && scale.x == scale.y && scale.z == scale.y, "\(radius): \(scale)")
        }
    }

    @Test(.enabled(if: camera("OM-System_OM-1-Mark-II") != nil))
    func `reads OM System's distortion tag`() throws {
        let url = try #require(Self.camera("OM-System_OM-1-Mark-II"))
        let lens = try #require(ImageDecoder.decode(url).lensCorrection)
        #expect(lens.source == .omSystem && lens.vignetting.isEmpty)
        // About the centre of the 5,184 × 3,888 photosites the JPEG shows, which sits 6 to the
        // left of the centre of LibRaw's 5,220 × 3,912.
        #expect(abs(lens.center.x - 2604.0 / 5220) < 1e-12 && lens.center.y == 0.5, "\(lens.center)")
        // The 12–40 mm at 25 mm: a barrel of 1.2% at the corners.
        for (radius, expected) in [(0.0, 1.0), (0.5, 0.995586), (1.0, 0.987872)] {
            let scale = lens.interpolate(lens.distortion, at: radius)
            #expect(abs(scale.y - expected) < 2e-5, "\(radius): \(scale)")
        }
    }

    @Test func `reads a Panasonic tag about the sensor's active area`() throws {
        // A barrel of 5% at the word-12 radius and the frame enlarged by 2%, on a frame whose
        // active area leaves 16 photosites at the right and 8 at the left.
        var words = [0, 0, 0, 0, 0, -655, 0, 0x1001, 1638, 0, 0, 0, 2500, 0, 0, 0]
        let data = Self.rw2(words: words, borders: (top: 0, left: 8, bottom: 3000, right: 4008))
        let frame = LensCorrectionReader.Frame(width: 4024, height: 3000)
        let url = URL(fileURLWithPath: "/tmp/t.rw2")
        let lens = try #require(LensCorrectionReader.read(data, url: url, orientation: 0, frame: frame))
        #expect(lens.source == .panasonic && lens.isValid)
        #expect(abs(lens.center.x - 2008.0 / 4024) < 1e-12 && lens.center.y == 0.5, "\(lens.center)")
        // Each corrected radius was recorded where the tag's polynomial corrects to it.
        let unit = 2500 / simd_length(SIMD2(2016.0, 1500.0))
        let scale = 1 - 655.0 / 32768
        for radius in [0.1, 0.4, 0.7, 1.0] {
            let corrected = radius / unit
            let recorded = corrected * lens.interpolate(lens.distortion, at: radius).y
            let back = recorded * (1 + 1638.0 / 32768 * recorded * recorded) / scale
            #expect(abs(back - corrected) < 1e-5, "\(radius): \(back) against \(corrected)")
        }
        #expect(abs(lens.interpolate(lens.distortion, at: 0).y - scale) < 1e-9)
        // A quarter turn turns the centre with the photo.
        let turned = try #require(LensCorrectionReader.read(data, url: url, orientation: 6, frame: frame))
        #expect(turned.center == SIMD2(0.5, 2008.0 / 4024))
        // Without the camera's correction, or without the frame it's placed in, there is none.
        words[7] = 0x1000
        let off = Self.rw2(words: words, borders: (top: 0, left: 8, bottom: 3000, right: 4008))
        #expect(LensCorrectionReader.read(off, url: url, orientation: 0, frame: frame) == nil)
        #expect(LensCorrectionReader.read(data, url: url, orientation: 0) == nil)
    }

    @Test func `a Panasonic polynomial that folds back inside the photo is refused`() {
        // r(1 + 0.3r² − 0.6r⁴) stops increasing at r = 0.86, short of the corners.
        let words = [0, 0, 0, 0, -19661, 0, 0, 1, 9830, 0, 0, 0, 2500, 0, 0, 0]
        let data = Self.rw2(words: words, borders: (top: 0, left: 0, bottom: 3000, right: 4000))
        let frame = LensCorrectionReader.Frame(width: 4000, height: 3000)
        #expect(LensCorrectionReader.read(data, url: URL(fileURLWithPath: "/tmp/t.rw2"), orientation: 0, frame: frame)
            == nil)
    }

    @Test(arguments: ["OM SYSTEM\0\0\0II\u{4}\0", "OLYMPUS\0II\u{3}\0"])
    func `reads an ORF's distortion tag about the camera's crop`(header: String) throws {
        let k: [Float] = [-0.08, 0.01, -0.001, 1.02]
        let data = Self.orf(header: header, coefficients: k, crop: (left: 8, top: 8, width: 4608, height: 3456))
        let frame = LensCorrectionReader.Frame(width: 4640, height: 3472)
        let lens = try #require(LensCorrectionReader.read(
            data, url: URL(fileURLWithPath: "/tmp/t.orf"), orientation: 0, frame: frame,
        ))
        #expect(lens.source == .omSystem && lens.isValid)
        #expect(abs(lens.center.x - 2312.0 / 4640) < 1e-12 && lens.center.y == 0.5, "\(lens.center)")
        // A corrected radius r was recorded at x(1 + k₁x² + k₂x⁴ + k₃x⁶), x = s·r, in the crop's
        // half-diagonal.
        let unit = 2880 / simd_length(SIMD2(2328.0, 1736.0))
        for radius in [0.0, 0.3, 0.6, 1.0] {
            let x = Double(k[3]) * radius / unit
            let expected = Double(k[3]) * (1 + Double(k[0]) * x * x + Double(k[1]) * pow(x, 4) + Double(k[2]) * pow(
                x,
                6,
            ))
            #expect(abs(lens.interpolate(lens.distortion, at: radius).y - expected) < 1e-5, "\(radius)")
        }
        let none = Self.orf(header: header, coefficients: [0, 0, 0, 1], crop: (8, 8, 4608, 3456))
        #expect(LensCorrectionReader.read(none, url: URL(fileURLWithPath: "/tmp/t.orf"), orientation: 0, frame: frame)
            == nil)
    }

    /// A little-endian IFD placed at `offset` in its file, with the values that don't fit in an
    /// entry after it.
    private static func ifd(_ entries: [(tag: UInt16, type: UInt16, count: Int, value: Data)], at offset: Int) -> Data {
        var head = Data(), tail = Data()
        head.append(le: UInt16(entries.count))
        let after = offset + 2 + entries.count * 12 + 4
        for entry in entries {
            head.append(le: entry.tag)
            head.append(le: entry.type)
            head.append(le: UInt32(entry.count))
            if entry.value.count <= 4 {
                head += entry.value + Data(count: 4 - entry.value.count)
            } else {
                head.append(le: UInt32(after + tail.count))
                tail += entry.value
            }
        }
        head.append(le: UInt32(0))
        return head + tail
    }

    private static func le(_ values: [some FixedWidthInteger]) -> Data {
        var data = Data()
        for value in values {
            data.append(le: value)
        }
        return data
    }

    /// An RW2 whose first IFD holds the sensor's borders and the distortion tag.
    private static func rw2(words: [Int], borders: (top: Int, left: Int, bottom: Int, right: Int)) -> Data {
        let short: (UInt16, Int) -> (tag: UInt16, type: UInt16, count: Int, value: Data) = { tag, value in
            (tag, 3, 1, le([UInt16(value)]))
        }
        return Data("IIU\0".utf8) + le([UInt32(8)]) + ifd([
            short(0x0004, borders.top), short(0x0005, borders.left), short(0x0006, borders.bottom),
            short(0x0007, borders.right),
            (0x0119, 7, 32, le(words.map { Int16(truncatingIfNeeded: $0) })),
        ], at: 8)
    }

    /// An ORF whose maker note's ImageProcessing IFD holds the crop and the distortion tag.
    private static func orf(
        header: String, coefficients: [Float], crop: (left: Int, top: Int, width: Int, height: Int),
    ) -> Data {
        let start = Data(header.utf8).count
        let processing = start + 18
        let note = Data(header.utf8) + ifd([(0x2040, 13, 1, le([UInt32(processing)]))], at: start) + ifd([
            (0x0612, 3, 2, le([UInt16(crop.left), 0])), (0x0613, 3, 2, le([UInt16(crop.top), 0])),
            (0x0614, 4, 1, le([UInt32(crop.width)])), (0x0615, 4, 1, le([UInt32(crop.height)])),
            (0x150A, 11, 4, le(coefficients.map(\.bitPattern))),
        ], at: processing)
        let exif = 8 + 18
        return Data("IIRO".utf8) + le([UInt32(8)]) + ifd([(0x8769, 4, 1, le([UInt32(exif)]))], at: 8)
            + ifd([(0x927C, 7, note.count, note)], at: exif)
    }
}

private extension Data {
    mutating func append(be value: some FixedWidthInteger) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func append(le value: some FixedWidthInteger) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
