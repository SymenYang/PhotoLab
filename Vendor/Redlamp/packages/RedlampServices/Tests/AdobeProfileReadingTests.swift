import Foundation
@_spi(Harness) import RedlampEngineAPI
import Testing
@testable import RedlampServices

/// Reading Adobe's camera profile formats (TON-51, TON-52), from synthetic files only.
struct AdobeProfileReadingTests {
    typealias Synthetic = SyntheticCameraProfiles

    static let matrix: [Double] = [0.6722, -0.0635, -0.0963, -0.4287, 1.2460, 0.2028, -0.0908, 0.2162, 0.5668]
    static let warmMatrix: [Double] = [0.7034, -0.0804, -0.1014, -0.4420, 1.1564, 0.3206, -0.0539, 0.1580, 0.7239]
    static let forward: [Double] = [0.7978, 0.1352, 0.0313, 0.2880, 0.7119, 0.0001, 0.0000, 0.0000, 0.8251]

    static func dcp(
        name: String = "Adobe Standard", camera: String = "Canon EOS R5", hueShift: Float = 4,
        lookTable: Synthetic.HSVTable? = .uniform(hues: 6, saturations: 2, values: 2, shift: SIMD3(2, 1.1, 1)),
        toneCurve: [SIMD2<Float>]? = nil, copyright: String = "Synthetic test profile", embedPolicy: Int = 1,
    ) -> Data {
        Synthetic.dcp(
            name: name, camera: camera, embedPolicy: embedPolicy, copyright: copyright,
            colorMatrices: [warmMatrix, matrix], forwardMatrices: [forward, forward],
            hueSatMaps: [
                .uniform(hues: 6, saturations: 2, shift: SIMD3(hueShift, 1, 1)),
                .uniform(shift: SIMD3(0, 1, 1)),
            ],
            lookTable: lookTable, toneCurve: toneCurve, baselineExposureOffset: 0.25,
        )
    }

    // MARK: - Big tables

    @Test func `a big table decodes to the bytes it was written from`() throws {
        let bytes = Data((0 ..< 1000).map { UInt8(truncatingIfNeeded: $0 * 7 + $0 / 13) })
        for count in [5, 6, 7, 8, 1000] {
            let text = Synthetic.bigTable(bytes.prefix(count))
            #expect(try AdobeTableEncoding.decode(text) == bytes.prefix(count))
        }
    }

    @Test func `a damaged big table is refused with a reason`() throws {
        let text = Synthetic.bigTable(Data((0 ..< 200).map { UInt8(truncatingIfNeeded: $0 * 73 + 41) }))
        #expect(throws: AdobeTableEncoding.DecodeError.truncated) {
            try AdobeTableEncoding.decode(String(text.prefix(6)))
        }
        #expect(throws: AdobeTableEncoding.DecodeError.invalidDigit) {
            try AdobeTableEncoding.decode("~" + text.dropFirst())
        }
        var damaged = Array(text)
        damaged[20] = damaged[20] == "a" ? "b" : "a"
        #expect(throws: AdobeTableEncoding.DecodeError.invalidStream) { try AdobeTableEncoding.decode(String(damaged)) }
    }

    // MARK: - DCP

    @Test func `a dcp reads its matrices, tables and curve`() throws {
        let curve: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(0.25, 0.3), SIMD2(1, 1)]
        let profile = try #require(DCPProfile(data: Self.dcp(toneCurve: curve)))
        #expect(profile.name == "Adobe Standard" && profile.cameraModel == "Canon EOS R5")
        #expect(profile.embedPolicy == 1 && profile.copyright == "Synthetic test profile")
        #expect(profile.color.calibrations.map(\.temperature) == [2856, 6504])
        #expect(profile.color.calibrations[1].colorMatrix == Self.matrix)
        #expect(profile.color.calibrations[0].forwardMatrix == Self.forward)
        #expect(profile.color.analogBalance == [1, 1, 1])
        #expect(profile.profile.hueSatMaps.count == 2 && profile.profile.hueSatMaps[0].entries[0] == 4)
        #expect(profile.profile.lookTable?.values == 2)
        #expect(profile.profile.toneCurve == curve && profile.profile.baselineExposureOffset == 0.25)
    }

    @Test func `a dcp of matrices alone is read`() throws {
        let data = Synthetic.dcp(
            name: "Matrix",
            camera: "Canon EOS R5",
            colorMatrices: [Self.matrix],
            illuminants: [21],
        )
        let profile = try #require(DCPProfile(data: data))
        #expect(profile.profile.isEmpty && profile.color.calibrations.count == 1)
    }

    @Test func `a dcp without a camera or matrices isn't one`() {
        #expect(DCPProfile(data: Synthetic.dcp(name: "No camera", camera: " ", colorMatrices: [Self.matrix])) == nil)
        #expect(DCPProfile(data: Synthetic.dcp(name: "No matrix", camera: "Canon EOS R5", colorMatrices: [])) == nil)
        #expect(DCPProfile(data: Data("not a profile".utf8)) == nil)
    }

    @Test func `a dcp's identity follows what renders, not its name`() throws {
        let identity = try #require(DCPProfile(data: Self.dcp())).identity
        #expect(identity.count == 16)
        #expect(try #require(DCPProfile(data: Self.dcp(name: "Renamed", copyright: "Other"))).identity == identity)
        #expect(try #require(DCPProfile(data: Self.dcp(hueShift: 5))).identity != identity)
    }

    @Test(arguments: [
        ("Canon EOS R5", "Canon", "EOS R5", true),
        ("Canon EOS R5", "Canon", "Canon EOS R5", true),
        ("Nikon Z 6_2", "NIKON CORPORATION", "NIKON Z 6_2", true),
        ("Sony ILCE-7M3", "Sony", "ILCE-7M3", true),
        ("OM Digital Solutions OM-1", "OM Digital Solutions", "OM-1", true),
        ("Canon EOS R5", "Canon", "EOS R6", false),
        ("Canon EOS R5", "Canon", "EOS R", false),
        ("Canon EOS R5", "Nikon", "EOS R5", false),
    ])
    func `Adobe's camera names match the photo's`(adobe: String, make: String, model: String, matches: Bool) {
        #expect(DCPProfile.names(adobe, camera: make, model) == matches)
    }

    // MARK: - XMP looks

    @Test func `an XMP look reads its tables, curve and settings`() throws {
        let rgb = Synthetic.RGBTable.grid(divisions: 3, primaries: 2, encoding: 1, amounts: 0 ... 1.5) { $0 * 0.5 }
        let data = Synthetic.xmpLook(
            name: "Artistic 01", baseProfile: nil, group: "Artistic", supportsAmount: true,
            lookTable: .uniform(
                hues: 6,
                saturations: 2,
                values: 1,
                shift: SIMD3(10, 1.2, 0.9),
                version: 2,
                amounts: 0.25 ... 1.75,
            ),
            rgbTable: rgb, rgbTableAmount: 0.5, toneCurve: [SIMD2(0, 10), SIMD2(128, 140), SIMD2(255, 255)],
            settings: ["Shadows2012": "+10", "Clarity2012": "0", "SplitToningShadowHue": "30"],
        )
        let look = try AdobeLook(xmp: data)
        #expect(look.name == "Artistic 01" && look.group == "Artistic" && look.cluster == "Adobe")
        #expect(look.baseProfile == nil && look.supportsAmount && !look.convertsToGrayscale)
        let table = try #require(look.lookTable)
        #expect(table.version == 2 && table.amounts == 0.25 ... 1.75 && table.map.entries.prefix(3) == [10, 1.2, 0.9])
        let colors = try #require(look.rgbTable)
        #expect(colors.isThreeDimensional && colors.divisions == 3 && colors.primaries == .proPhoto)
        #expect(colors.encoding == .sRGB && colors.amounts == 0 ... 1.5 && look.rgbTableAmount == 0.5)
        // Red outermost: the sample after the first two whole blue runs is red 0, green 2, blue 0.
        #expect(abs(colors.samples[6 * 3 + 1] - 0.5) < 1e-4 && abs(colors.samples[6 * 3]) < 1e-4)
        #expect(look.toneCurve?.first == SIMD2(0, 10) / 255 && look.toneCurve?.count == 3)
        #expect(look.leftOut.sorted() == ["Shadows +10", "Split Toning Shadow Hue 30"])
    }

    @Test func `a 1D color table is a curve per channel`() throws {
        let table = Synthetic.RGBTable(
            threeDimensional: false, divisions: 4, samples: [0, 0.2, 0.7, 1].map { SIMD3($0, $0 * 0.5, 1 - $0) },
        )
        let decoded = try AdobeRGBTable(bytes: Synthetic.rgbTableBytes(table))
        #expect(!decoded.isThreeDimensional && decoded.divisions == 4)
        let expected: [Float] = [0, 0, 1, 0.2, 0.1, 0.8, 0.7, 0.35, 0.3, 1, 0.5, 0]
        #expect(zip(decoded.samples, expected).allSatisfy { abs($0 - $1) < 2e-5 })
    }

    @Test func `a look's identity follows its tables`() throws {
        func look(_ shift: Float) throws -> AdobeLook {
            try AdobeLook(xmp: Synthetic.xmpLook(name: "Adobe Color", lookTable: .uniform(shift: SIMD3(shift, 1, 1))))
        }
        #expect(try look(3).identity == look(3).identity)
        #expect(try look(3).identity != look(4).identity)
    }

    @Test func `looks Redlamp can't render are refused with a reason`() {
        let table = Synthetic.HSVTable.uniform(shift: SIMD3(1, 1, 1))
        #expect(throws: AdobeLook.ReadError.needsPhotoTables) {
            try AdobeLook(xmp: Synthetic.xmpLook(name: "Needs", lookTable: table, requiresRGBTables: true))
        }
        #expect(throws: AdobeLook.ReadError.missingTable("look table")) {
            try AdobeLook(xmp: Synthetic.xmpLook(
                name: "Camera PROVIA/Standard",
                lookTable: table,
                omittingTables: true,
            ))
        }
        #expect(throws: AdobeLook.ReadError.nothingToRender) {
            try AdobeLook(xmp: Synthetic.xmpLook(name: "Adaptive"))
        }
        let preset = Data(String(decoding: Synthetic.xmpLook(name: "Preset", lookTable: table), as: UTF8.self)
            .replacingOccurrences(of: "crs:PresetType=\"Look\"", with: "crs:PresetType=\"Normal\"").utf8)
        #expect(throws: AdobeLook.ReadError.notALook) { try AdobeLook(xmp: preset) }
        #expect(throws: AdobeLook.ReadError.notXMP) { try AdobeLook(xmp: Data("<x".utf8)) }
    }

    // MARK: - Finding them

    @Test func `the library finds the photo's camera's profiles and the looks over them`() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "camera-profiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appending(path: "Shared")
        let user = root.appending(path: "User")
        func write(_ data: Data, _ path: String, in folder: URL = shared) throws {
            let url = folder.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try data.write(to: url)
        }
        try write(Self.dcp(), "CameraProfiles/Adobe Standard/Canon EOS R5 Adobe Standard.dcp")
        try write(
            Self.dcp(camera: "Canon EOS R6", hueShift: 6),
            "CameraProfiles/Adobe Standard/Canon EOS R6 Adobe Standard.dcp",
        )
        try write(
            Self.dcp(name: "Camera Standard", hueShift: 1),
            "CameraProfiles/Camera/Canon EOS R5/Canon EOS R5 Camera Standard.dcp",
        )
        let color = Synthetic.HSVTable.uniform(shift: SIMD3(3, 1.1, 1))
        try write(
            Synthetic.xmpLook(name: "Adobe Color", lookTable: color),
            "Settings/Adobe/Profiles/Adobe Raw/Adobe Color.xmp",
        )
        try write(
            Synthetic.xmpLook(
                name: "Vintage 01",
                baseProfile: nil,
                group: "Vintage",
                lookTable: .uniform(shift: SIMD3(8, 1, 1)),
            ),
            "Settings/Adobe/Profiles/Creative/Vintage 01.xmp",
        )
        try write(
            Synthetic.xmpLook(
                name: "Camera Faithful",
                camera: "Canon EOS R6",
                lookTable: .uniform(shift: SIMD3(2, 1, 1)),
            ),
            "Settings/Adobe/Profiles/Camera/Faithful.xmp",
        )
        try write(Data("not a profile".utf8), "CameraProfiles/broken.dcp", in: user)
        try write(Self.dcp(name: "My Profile", hueShift: 9), "CameraProfiles/Mine/My Profile.dcp", in: user)
        // The same look again in the photographer's folder is listed once.
        try write(
            Synthetic.xmpLook(name: "Adobe Color", lookTable: color),
            "Settings/Copy of Adobe Color.xmp",
            in: user,
        )
        let chosen = root.appending(path: "Chosen/Grain.xmp")
        try write(
            Synthetic.xmpLook(name: "Grain", baseProfile: nil, cluster: nil, lookTable: color.with(shift: 12)),
            "Chosen/Grain.xmp",
            in: root,
        )

        let library = CameraProfileLibrary(locations: .init(cameraRaw: shared, userCameraRaw: user, chosen: [chosen]))
        let found = library.profiles(make: "Canon", model: "EOS R5")
        #expect(found.profiles.map(\.dcp.name) == ["Adobe Standard", "Camera Standard", "My Profile"])
        #expect(found.profiles.map(\.source) == [.adobeRaw, .cameraMatching, .own])
        #expect(found.looks.map(\.look.name) == ["Adobe Color", "Vintage 01", "Grain"])
        #expect(found.looks.map(\.source) == [.adobeRaw, .creative, .own])
        let adobeColor = try #require(found.looks.first?.look)
        #expect(found.base(for: adobeColor)?.dcp.name == "Adobe Standard")
        #expect(library.issues.keys.map(\.lastPathComponent) == ["broken.dcp"])

        let other = library.profiles(make: "Canon", model: "EOS R6")
        #expect(other.profiles.map(\.dcp.name) == ["Adobe Standard"])
        #expect(other.looks.map(\.look.name).contains("Camera Faithful"))
        #expect(library.profiles(make: "Nikon", model: "Z 8").profiles.isEmpty)
        #expect(library.issue(with: chosen) == nil)
        #expect(library.issue(with: user.appending(path: "CameraProfiles/broken.dcp")) != nil)
    }
}

private extension SyntheticCameraProfiles.HSVTable {
    func with(shift: Float) -> Self {
        var copy = self
        copy.entries = entries.enumerated().map { $0.offset % 3 == 0 ? shift : $0.element }
        return copy
    }
}
