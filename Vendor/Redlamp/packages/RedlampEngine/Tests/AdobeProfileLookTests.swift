import Foundation
import Metal
import RedlampColor
@_spi(Harness) import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// The photographer's Adobe camera profiles as Base Looks (TON-51, TON-52), from synthetic
/// profiles only: Adobe's files are never committed (DEC-85).
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct AdobeProfileLookTests {
    typealias Synthetic = SyntheticCameraProfiles

    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let kernels: KernelLibrary

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        kernels = try KernelLibrary(device: device)
    }

    static let colorMatrix: [Double] = [0.6722, -0.0635, -0.0963, -0.4287, 1.2460, 0.2028, -0.0908, 0.2162, 0.5668]
    static let forward: [Double] = [0.7978, 0.1352, 0.0313, 0.2880, 0.7119, 0.0001, 0.0000, 0.0000, 0.8251]

    static func base(lookTable: Bool = true, curve: Bool = true) throws -> DNGProfile {
        let look = Synthetic.HSVTable.uniform(hues: 6, saturations: 2, values: 1, shift: SIMD3(6, 1.15, 0.97))
        let data = Synthetic.dcp(
            name: "Adobe Standard", camera: "Canon EOS R5", colorMatrices: [colorMatrix], illuminants: [21],
            forwardMatrices: [forward], lookTable: lookTable ? look : nil,
            toneCurve: curve ? [SIMD2(0, 0), SIMD2(0.1, 0.16), SIMD2(0.5, 0.62), SIMD2(1, 1)] : nil,
            baselineExposureOffset: 0.2,
        )
        return try #require(DCPProfile(data: data)).profile
    }

    static func look(
        supportsAmount: Bool = false, table: Synthetic.HSVTable? = .uniform(shift: SIMD3(12, 1.2, 1)),
        curve: [SIMD2<Float>]? = nil, rgb: Synthetic.RGBTable? = nil,
    ) throws -> AdobeLook {
        try AdobeLook(xmp: Synthetic.xmpLook(
            name: "Adobe Color", supportsAmount: supportsAmount, lookTable: table, rgbTable: rgb, toneCurve: curve,
        ))
    }

    // MARK: - The bake

    @Test(arguments: [(true, true), (true, false), (false, true)])
    func `a profile's look bakes as a DNG's own look does`(lookTable: Bool, curve: Bool) throws {
        let base = try Self.base(lookTable: lookTable, curve: curve)
        let baked = try #require(ProfileLookBake(base: base, look: nil).table(amount: 100))
        let embedded = try #require(EmbeddedLook.definition(for: base)?.table)
        #expect(baked.values == embedded.values && baked.space == .sceneLog)
    }

    @Test func `a profile of matrices alone has no table`() throws {
        let base = try Self.base(lookTable: false, curve: false)
        #expect(!ProfileLookBake(base: base, look: nil).hasTable)
        #expect(ProfileLookBake(base: base, look: nil).table(amount: 100) == nil)
    }

    @Test func `an XMP look at Amount 0 is its base profile`() throws {
        let base = try Self.base()
        let look = try Self.look(curve: [SIMD2(0, 0), SIMD2(128, 150), SIMD2(255, 255)])
        let bake = ProfileLookBake(base: base, look: look)
        let plain = try #require(ProfileLookBake(base: base, look: nil).table(amount: 100))
        #expect(try #require(bake.table(amount: 0)).values == plain.values)
        #expect(try #require(bake.table(amount: 100)).values != plain.values)
    }

    @Test func `the look's curve is mixed in to 100 and applied again above`() {
        let curve = LookCurve(points: [SIMD2(0, 0), SIMD2(0.5, 0.7), SIMD2(1, 1)], amount: 1)
        let once = curve.evaluate(0.5)
        #expect(abs(once - 0.7) < 1e-5)
        #expect(abs(LookCurve(points: [SIMD2(0, 0), SIMD2(0.5, 0.7), SIMD2(1, 1)], amount: 0.5).evaluate(0.5) - 0.6) <
            1e-5)
        let twice = LookCurve(points: [SIMD2(0, 0), SIMD2(0.5, 0.7), SIMD2(1, 1)], amount: 2).evaluate(0.5)
        #expect(abs(twice - curve.evaluate(once)) < 1e-5)
        // Greys stay grey, and the darkest and brightest channels go through the curve.
        let grey = curve.apply(SIMD3(repeating: 0.2))
        #expect(abs(grey.x - grey.y) < 1e-6 && abs(grey.y - grey.z) < 1e-6)
        let colour = curve.apply(SIMD3(0.4, 0.2, 0.1))
        #expect(abs(SRGB.encode(colour.x) - curve.evaluate(SRGB.encode(0.4))) < 1e-4)
        #expect(abs(SRGB.encode(colour.z) - curve.evaluate(SRGB.encode(0.1))) < 1e-4)
    }

    @Test func `a look table scales as Camera Raw scales one`() throws {
        let map = try #require(DNGProfile.HSVMap(hues: 2, saturations: 2, values: 1, entries: [
            10, 1.2, 0.8, 10, 1.2, 0.8, -20, 0.5, 1.1, -20, 0.5, 1.1,
        ], srgbValues: false))
        let half = ProfileLookBake.scaled(map, by: 0.5).entries
        #expect(zip(half, [5, 1.1, 0.9, 5, 1.1, 0.9, -10, 0.75, 1.05, -10, 0.75, 1.05])
            .allSatisfy { abs($0 - $1) < 1e-6 })
        #expect(ProfileLookBake.scaled(map, by: 2).entries[7] == 0)
    }

    @Test func `a look's strength stays within its table's bounds`() throws {
        let base = try Self.base()
        let bounded = try Self.look(
            supportsAmount: true, table: .uniform(shift: SIMD3(12, 1.2, 1), version: 2, amounts: 0.25 ... 1.75),
        )
        let bake = ProfileLookBake(base: base, look: bounded)
        #expect(try #require(bake.table(amount: 200)).values == #require(bake.table(amount: 175)).values)
        #expect(try #require(bake.table(amount: 10)).values == #require(bake.table(amount: 25)).values)
        // A version 1 table stays whole at any Amount, in a look Lightroom gives an Amount.
        let fixed = try ProfileLookBake(base: base, look: Self.look(supportsAmount: true))
        #expect(try #require(fixed.table(amount: 40)).values == #require(fixed.table(amount: 100)).values)
        // The Adobe Raw looks have no Amount in Lightroom; Redlamp's scales them freely.
        let free = try ProfileLookBake(base: base, look: Self.look())
        #expect(try #require(free.table(amount: 40)).values != #require(free.table(amount: 100)).values)
    }

    // MARK: - RGB tables

    static func rgbTable(_ table: Synthetic.RGBTable) throws -> AdobeRGBTable {
        let look = try AdobeLook(xmp: Synthetic.xmpLook(name: "Modern 01", baseProfile: nil, rgbTable: table))
        return try #require(look.rgbTable)
    }

    @Test func `an identity color table changes nothing`() throws {
        let table = try Self.rgbTable(.grid(divisions: 17) { $0 })
        let math = RGBTableMath(table: table, amount: 1)
        // Inside sRGB, the table's space: outside it, the table clips.
        for srgb in [SIMD3<Float>(0.2, 0.3, 0.4), SIMD3(0.7, 0.1, 0.05), SIMD3(0.01, 0.5, 0.9)] {
            let colour = ColorMatrices.sRGBToRec2020.floatMatrix * srgb
            #expect(simd_abs(math.apply(colour) - colour).max() < 2e-3, "\(colour)")
        }
    }

    @Test func `a color table moves colours by its amount, in its own encoding`() throws {
        let table = try Self.rgbTable(.grid(divisions: 9, primaries: 0, encoding: 1) { $0 * 0.5 })
        let colour = SIMD3<Float>(0.3, 0.2, 0.1)
        let srgb = ColorMatrices.rec2020ToSRGB.floatMatrix * colour
        for amount: Float in [1, 0.5] {
            let expected = ColorMatrices.sRGBToRec2020.floatMatrix * SIMD3(
                SRGB.decode(SRGB.encode(srgb.x) * (1 - amount / 2)),
                SRGB.decode(SRGB.encode(srgb.y) * (1 - amount / 2)),
                SRGB.decode(SRGB.encode(srgb.z) * (1 - amount / 2)),
            )
            #expect(simd_abs(RGBTableMath(table: table, amount: amount).apply(colour) - expected).max() < 1e-3)
        }
    }

    @Test func `a 3D table of a curve per channel gives what the 1D table gives`() throws {
        func curve(_ x: Float) -> Float {
            x * x * (3 - 2 * x)
        }
        let flat = try Self.rgbTable(Synthetic.RGBTable(
            threeDimensional: false, divisions: 9,
            samples: (0 ..< 9).map { SIMD3(repeating: curve(Float($0) / 8)) },
        ))
        let grid = try Self.rgbTable(.grid(divisions: 9) { SIMD3(curve($0.x), curve($0.y), curve($0.z)) })
        for colour in [SIMD3<Float>(0.2, 0.33, 0.47), SIMD3(0.61, 0.09, 0.3)] {
            let a = RGBTableMath(table: flat, amount: 1).apply(colour)
            let b = RGBTableMath(table: grid, amount: 1).apply(colour)
            #expect(simd_abs(a - b).max() < 1e-4, "\(a) vs \(b)")
        }
    }

    @Test func `a table that extends the gamut keeps what clipping took`() throws {
        var extending = Synthetic.RGBTable.grid(divisions: 5, encoding: 0) { $0 }
        extending.extendsGamut = true
        let table = try Self.rgbTable(extending)
        let bright = ColorMatrices.sRGBToRec2020.floatMatrix * SIMD3<Float>(1.4, 0.5, 0.2)
        let kept = RGBTableMath(table: table, amount: 1).apply(bright)
        #expect(simd_abs(kept - bright).max() < 1e-3)
        let clipped = try RGBTableMath(table: Self.rgbTable(.grid(divisions: 5, encoding: 0) { $0 }), amount: 1)
            .apply(bright)
        #expect((ColorMatrices.rec2020ToSRGB.floatMatrix * clipped).x < 1.001)
    }

    // MARK: - Rendering

    static let patches: [SIMD3<Float>] = [
        SIMD3(0.45, 0.3, 0.25), SIMD3(0.3, 0.32, 0.35), SIMD3(0.6, 0.55, 0.5), SIMD3(0.2, 0.25, 0.1),
        SIMD3(0.35, 0.2, 0.3), SIMD3(0.25, 0.4, 0.2),
    ]
    static let patchSize = 8

    func session(_ colors: [SIMD3<Float>], model: String = "EOS R5") throws -> ImageSession {
        let size = Self.patchSize
        let (width, height) = (size * colors.count, size)
        let white: Float = 65535
        var samples = [UInt16](repeating: 0, count: width * height * 3)
        for y in 0 ..< height {
            for x in 0 ..< width {
                for channel in 0 ..< 3 {
                    samples[(y * width + x) * 3 + channel] = UInt16((min(max(colors[x / size][channel], 0), 1) * white)
                        .rounded())
                }
            }
        }
        var info = ImageInfo(
            url: URL(fileURLWithPath: "/patches.cr3"), pixelSize: PixelSize(width: width, height: height), isRaw: true,
            sensorDescription: "synthetic",
        )
        info.make = "Canon"
        info.model = model
        let decoded = DecodedImage(
            width: width, height: height, layout: .linearRGB, samples: samples, blackLevels: [0, 0, 0],
            whiteLevel: white, asShotMultipliers: SIMD3(1, 1, 1), cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            xyzToCamera: nil, orientation: 0, baselineExposure: 0, info: info,
        )
        return try SessionBuilder(device: device, queue: queue, kernels: kernels).build(decoded)
    }

    func render(_ session: ImageSession, look: BaseLookReference, engine: RedlampEngine) throws -> [SIMD3<Float>] {
        var recipe = EditRecipe()
        recipe.baseLook = look
        let frame = try engine.renderFrame(
            RenderRequest(recipe: recipe, targetSize: session.orientedSize, generation: 0), session: session,
        )
        let surface = frame.surface
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let row = (IOSurfaceGetBaseAddress(surface) + Self.patchSize / 2 * IOSurfaceGetBytesPerRow(surface))
            .assumingMemoryBound(to: Float16.self)
        return (0 ..< session.orientedSize.width / Self.patchSize).map { patch in
            let x = patch * Self.patchSize + Self.patchSize / 2
            return SIMD3(Float(row[x * 4]), Float(row[x * 4 + 1]), Float(row[x * 4 + 2]))
        }
    }

    /// An engine reading profiles from a folder of its own, as the photographer's Camera Raw folder.
    func engine(with files: [String: Data]) throws -> (RedlampEngine, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "adobe-looks-\(UUID().uuidString)")
        for (path, data) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try data.write(to: url)
        }
        let library = CameraProfileLibrary(locations: .init(cameraRaw: nil, userCameraRaw: root))
        return try (RedlampEngine(stillTile: 2048, cameraProfiles: library), root)
    }

    @Test func `an Adobe look renders with its profile's matrices and HueSatMap`() throws {
        let map = try HueSatMapTests.map(values: 1, srgb: false)
        let dcpData = Synthetic.dcp(
            name: "Adobe Standard", camera: "Canon EOS R5", colorMatrices: [Self.colorMatrix], illuminants: [21],
            forwardMatrices: [Self.forward],
            hueSatMaps: [Synthetic.HSVTable(
                hues: map.hues,
                saturations: map.saturations,
                values: 1,
                entries: map.entries,
            )],
        )
        let dcp = try #require(DCPProfile(data: dcpData))
        let (engine, root) = try engine(with: ["CameraProfiles/Adobe Standard.dcp": dcpData])
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = try session(Self.patches)
        let reference = BaseLookReference(
            id: BaseLookReference.adobeIDPrefix + dcp.identity, version: ProfileLookBake.version,
            name: "Adobe Standard",
        )
        let rendered = try render(photo, look: reference, engine: engine)

        let toWorking = photo.cameraToWorking
        let profileToWorking = ProfileCalibration(dcp, device: device).cameraToWorking(
            for: EditRecipe(),
            session: photo,
        )
        let toProPhoto = HueSatMaps.workingToProPhoto
        let expected = Self.patches.map { camera in
            let corrected = HueSatMapTests.reference(toProPhoto * (profileToWorking * camera), map)
            return toWorking.inverse * (toProPhoto.inverse * corrected)
        }
        #expect(expected.allSatisfy { $0.min() >= 0 && $0.max() <= 1 }, "\(expected)")
        let wanted = try render(session(expected), look: BuiltInBaseLook.color.reference, engine: engine)
        #expect(HueSatMapTests.worst(rendered, wanted) < 2e-3, "\(rendered) vs \(wanted)")
        // Redlamp's own looks keep the camera's calibration.
        let plain = try render(photo, look: BuiltInBaseLook.color.reference, engine: engine)
        let unprofiled = try render(
            photo,
            look: BuiltInBaseLook.color.reference,
            engine: RedlampEngine(stillTile: 2048),
        )
        #expect(plain == unprofiled)
        #expect(HueSatMapTests.worst(rendered, plain) > 0.01, "the profile should change the colours")
    }

    @Test func `an XMP look renders over its base, at its Amount`() throws {
        let dcpData = Synthetic.dcp(
            name: "Adobe Standard", camera: "Canon EOS R5", colorMatrices: [Self.colorMatrix], illuminants: [21],
            forwardMatrices: [Self.forward], toneCurve: [SIMD2(0, 0), SIMD2(0.18, 0.4), SIMD2(1, 1)],
        )
        let lookData = Synthetic.xmpLook(
            name: "Adobe Vivid", lookTable: .uniform(shift: SIMD3(0, 1.4, 1)),
            toneCurve: [SIMD2(0, 0), SIMD2(64, 50), SIMD2(192, 210), SIMD2(255, 255)],
        )
        let dcp = try #require(DCPProfile(data: dcpData))
        let look = try AdobeLook(xmp: lookData)
        let (engine, root) = try engine(with: ["CameraProfiles/Standard.dcp": dcpData, "Settings/Vivid.xmp": lookData])
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = try session(Self.patches)
        let vivid = BaseLookReference(
            id: BaseLookReference.adobeIDPrefix + dcp.identity + "/" + look.identity, version: ProfileLookBake.version,
            name: "Adobe Vivid",
        )
        let standard = BaseLookReference(
            id: BaseLookReference.adobeIDPrefix + dcp.identity, version: ProfileLookBake.version,
            name: "Adobe Standard",
        )
        let full = try render(photo, look: vivid, engine: engine)
        let none = try render(photo, look: vivid.withAmount(0), engine: engine)
        let base = try render(photo, look: standard, engine: engine)
        #expect(none == base, "Amount 0 is the base profile")
        #expect(HueSatMapTests.worst(full, base) > 0.01, "the look changes the colours")
        let double = try render(photo, look: vivid.withAmount(200), engine: engine)
        #expect(HueSatMapTests.worst(double, full) > 0.005)
    }

    @Test func `a look chosen over another camera's profile renders over this camera's`() throws {
        func standard(_ camera: String, shift: Float) -> Data {
            Synthetic.dcp(
                name: "Adobe Standard", camera: camera, colorMatrices: [Self.colorMatrix], illuminants: [21],
                forwardMatrices: [Self.forward], toneCurve: [SIMD2(0, 0), SIMD2(0.18, 0.35), SIMD2(1, 1)],
                baselineExposureOffset: Double(shift) / 100,
            )
        }
        let r5 = standard("Canon EOS R5", shift: 10), r6 = standard("Canon EOS R6", shift: 20)
        let colorData = Synthetic.xmpLook(name: "Adobe Color", lookTable: .uniform(shift: SIMD3(8, 1.2, 1)))
        let faithful = Synthetic.xmpLook(
            name: "Camera Faithful",
            camera: "Canon EOS R5",
            lookTable: .uniform(shift: SIMD3(2, 1, 1)),
        )
        let (engine, root) = try engine(with: [
            "CameraProfiles/R5.dcp": r5, "CameraProfiles/R6.dcp": r6, "Settings/Color.xmp": colorData,
            "Settings/Faithful.xmp": faithful,
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let (dcp5, dcp6) = try (#require(DCPProfile(data: r5)), #require(DCPProfile(data: r6)))
        let color = try AdobeLook(xmp: colorData)
        func reference(_ dcp: DCPProfile, look: AdobeLook? = nil, name: String) -> BaseLookReference {
            BaseLookReference(
                id: BaseLookReference.adobeIDPrefix + dcp.identity + (look.map { "/" + $0.identity } ?? ""),
                version: ProfileLookBake.version, name: name,
            )
        }
        let photo = try session(Self.patches, model: "EOS R6")
        let own = try render(photo, look: reference(dcp6, look: color, name: "Adobe Color"), engine: engine)
        #expect(try render(photo, look: reference(dcp5, look: color, name: "Adobe Color"), engine: engine) == own)
        let ownStandard = try render(photo, look: reference(dcp6, name: "Adobe Standard"), engine: engine)
        #expect(try render(photo, look: reference(dcp5, name: "Adobe Standard"), engine: engine) == ownStandard)
        // The R5's own profile never calibrates the R6's photo, even once registered.
        _ = try render(session(Self.patches), look: reference(dcp5, name: "Adobe Standard"), engine: engine)
        #expect(try render(photo, look: reference(dcp5, name: "Adobe Standard"), engine: engine) == ownStandard)
        // A look made for the R5 alone has nothing to go over on the R6: Redlamp's look stands in.
        let r5Only = try reference(dcp5, look: AdobeLook(xmp: faithful), name: "Camera Faithful")
        #expect(!engine.resolveBaseLook(r5Only, session: photo).isAvailable)
    }

    @Test func `where the profile isn't on this Mac, Redlamp's look of the same name stands in`() throws {
        let (engine, root) = try engine(with: [:])
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = try session(Self.patches)
        let missing = BaseLookReference(
            id: BaseLookReference.adobeIDPrefix + "00112233aabbccdd/8899aabbccddeeff",
            name: "Adobe Vivid",
        )
        #expect(!engine.canRender(missing))
        let resolved = engine.resolveBaseLook(missing, session: photo)
        #expect(!resolved.isAvailable && resolved.calibration == nil)
        #expect(try render(photo, look: missing, engine: engine) == render(
            photo,
            look: BuiltInBaseLook.vivid.reference,
            engine: engine,
        ))
    }

    // MARK: - The menu's list

    @Test func `a camera's looks are listed in Lightroom's groups, each over its base`() throws {
        let standard = Synthetic.dcp(
            name: "Adobe Standard",
            camera: "Canon EOS R5",
            colorMatrices: [Self.colorMatrix],
            illuminants: [21],
        )
        let faithful = Synthetic.dcp(
            name: "Camera Faithful", camera: "Canon EOS R5", colorMatrices: [Self.colorMatrix], illuminants: [21],
            lookTable: .uniform(shift: SIMD3(1, 1, 1)),
        )
        let table = Synthetic.HSVTable.uniform(shift: SIMD3(3, 1, 1))
        let root = FileManager.default.temporaryDirectory.appending(path: "adobe-groups-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let files: [String: Data] = [
            "Shared/CameraProfiles/Adobe Standard/Canon EOS R5 Adobe Standard.dcp": standard,
            "Shared/CameraProfiles/Camera/Canon EOS R5/Canon EOS R5 Camera Faithful.dcp": faithful,
            "Shared/Settings/Adobe/Profiles/Adobe Raw/Adobe Monochrome.xmp": Synthetic.xmpLook(
                name: "Adobe Monochrome", grayscale: true, lookTable: table, settings: ["Clarity2012": "+8"],
            ),
            "Shared/Settings/Adobe/Profiles/Adobe Raw/Adobe Color.xmp": Synthetic.xmpLook(
                name: "Adobe Color", lookTable: table.with(shift: 4),
            ),
            "Shared/Settings/Adobe/Profiles/Creative/B&W 01.xmp": Synthetic.xmpLook(
                name: "B&W 01", baseProfile: nil, group: "B&W", lookTable: table.with(shift: 5),
            ),
            "Shared/Settings/Adobe/Profiles/Creative/Over Neutral.xmp": Synthetic.xmpLook(
                name: "Needs Neutral", baseProfile: "Camera Neutral", group: "Modern", lookTable: table.with(shift: 6),
            ),
        ]
        for (path, data) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try data.write(to: url)
        }
        let library = CameraProfileLibrary(locations: .init(
            cameraRaw: root.appending(path: "Shared"),
            userCameraRaw: nil,
        ))
        let looks = CameraProfileLooks(library: library, device: device)
        let entries = looks.looks(make: "Canon", model: "EOS R5", refresh: true).found
        #expect(entries.map(\.descriptor.reference.name) == [
            "Adobe Color", "Adobe Monochrome", "Adobe Standard", "Camera Faithful", "B&W 01",
        ])
        #expect(entries.map(\.descriptor.group) == [.adobeRaw, .adobeRaw, .adobeRaw, .cameraMatching, .creative("B&W")])
        let standardID = try #require(entries.first { $0.descriptor.reference.name == "Adobe Standard" }).look.reference
            .id
        let color = try #require(entries.first)
        #expect(color.look.reference.id.hasPrefix(standardID + "/") && color.look.amountInTable)
        #expect(color.look.reference.contentHash == nil && color.look.reference.staysOnThisMac)
        let monochrome = try #require(entries.first { $0.descriptor.reference.name == "Adobe Monochrome" })
        #expect(monochrome.descriptor.isMonochrome && monochrome.look.parameters.isMonochrome)
        #expect(monochrome.descriptor.summary.contains("Clarity +8") && monochrome.descriptor.leftOut == ["Clarity +8"])
        #expect(entries.filter { !$0.descriptor.leftOut.isEmpty }
            .map(\.descriptor.reference.name) == ["Adobe Monochrome"])
        #expect(looks.looks(make: "Canon", model: "EOS R6", refresh: true).found.isEmpty)

        // Files chosen through the library, by any engine sharing it, are found without a refresh.
        let chosen = root.appending(path: "Grain.xmp")
        try Synthetic.xmpLook(name: "Grain", baseProfile: nil, cluster: nil, lookTable: table.with(shift: 9))
            .write(to: chosen)
        #expect(looks.looks(make: "Canon", model: "EOS R5", refresh: false).found.count == entries.count)
        library.setChosen([chosen])
        #expect(looks.looks(make: "Canon", model: "EOS R5", refresh: false).found.count == entries.count + 1)

        // A profile taken off the Mac is gone at the next listing, with the looks over it.
        try FileManager.default.removeItem(at: root.appending(path: "Shared/CameraProfiles/Adobe Standard"))
        let after = looks.looks(make: "Canon", model: "EOS R5", refresh: true)
        #expect(after.found.map(\.descriptor.reference.name) == ["Camera Faithful"])
        #expect(Set(after.gone.map(\.name)) == ["Adobe Color", "Adobe Monochrome", "Adobe Standard", "B&W 01", "Grain"])
        let registry = try BaseLookRegistry(device: device)
        entries.forEach { registry.register($0.look) }
        registry.unregister(after.gone)
        #expect(!registry.canRender(color.look.reference) && registry.canRender(after.found[0].look.reference))
    }

    @Test func `a camera's looks are listed without opening a photo, as its photos render them`() async throws {
        let standard = Synthetic.dcp(
            name: "Adobe Standard", camera: "Canon EOS R5", colorMatrices: [Self.colorMatrix], illuminants: [21],
            forwardMatrices: [Self.forward],
        )
        let color = Synthetic.xmpLook(name: "Adobe Color", lookTable: .uniform(shift: SIMD3(8, 1.2, 1)))
        let (engine, root) = try engine(with: ["CameraProfiles/R5.dcp": standard, "Settings/Color.xmp": color])
        defer { try? FileManager.default.removeItem(at: root) }
        let looks = await engine.cameraProfileLooks(make: "Canon", model: "EOS R5")
        #expect(looks.map(\.reference.name) == ["Adobe Color", "Adobe Standard"])
        // A catalog names the camera as its EXIF does, the make repeated.
        #expect(await engine.cameraProfileLooks(make: "Canon", model: "Canon EOS R5") == looks)
        #expect(await engine.cameraProfileLooks(make: "Canon", model: "EOS R6").isEmpty)
        let photo = try session(Self.patches)
        for look in looks {
            let resolved = engine.resolveBaseLook(look.reference, session: photo)
            #expect(resolved.isAvailable && resolved.calibration != nil, "\(look.reference.name)")
        }
        let unprofiled = try RedlampEngine(stillTile: 2048)
        #expect(await unprofiled.cameraProfileLooks(make: "Canon", model: "EOS R5").isEmpty)
    }
}

private extension SyntheticCameraProfiles.HSVTable {
    func with(shift: Float) -> Self {
        var copy = self
        copy.entries = entries.enumerated().map { $0.offset % 3 == 0 ? shift : $0.element }
        return copy
    }
}
