import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampServices

/// Choosing a user's lens profile for a photo, only for a raw whose file carries no correction of
/// its own: by camera and lens from the Lens Profiles folder (LNS-04), and from process 17 one made
/// on another body (LNS-14) or found in Camera Raw's folders (LNS-16).
struct LCPProfileLibraryTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "lens-profiles-\(UUID().uuidString)")

    /// A Nikon Z 6 raw shot with its 24-70 mm zoom at 24 mm and f/4, named as LibRaw names them.
    static let info = ImageInfo(
        url: URL(fileURLWithPath: "/DSC_0001.NEF"), pixelSize: PixelSize(width: 6000, height: 4000), isRaw: true,
        sensorDescription: "Bayer RGGB", make: "Nikon", model: "Z 6", lens: "NIKKOR Z 24-70mm f/4 S", aperture: 4,
        focalLength: 24,
    )

    @discardableResult
    private func write(_ specs: [SyntheticLCP.Spec], to name: String = "Nikon/Z 6 24-70.lcp") throws -> URL {
        let url = directory.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SyntheticLCP.file(specs).write(to: url)
        return url
    }

    private func correction(
        _ info: ImageInfo = LCPProfileLibraryTests.info, in library: LCPProfileLibrary? = nil,
    ) -> LensCorrection? {
        (library ?? LCPProfileLibrary(directory: directory))
            .correction(for: info, sensorSize: PixelSize(width: 6000, height: 4000), orientation: 0)
    }

    private static func decoded(
        _ info: ImageInfo, lens: LensCorrection?, layout: DecodedImage.Layout = .linearRGB,
    ) -> DecodedImage {
        var image = DecodedImage(
            width: 6000, height: 4000, layout: layout, samples: [], blackLevels: [0, 0, 0], whiteLevel: 1,
            asShotMultipliers: SIMD3(1, 1, 1), cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1], xyzToCamera: nil,
            orientation: 0, baselineExposure: 0, info: info,
        )
        image.lensCorrection = lens
        return image
    }

    @Test func `matches the camera and the lens however EXIF and LibRaw spell them`() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try write([SyntheticLCP.Spec()])
        let lens = try #require(correction())
        #expect(lens.source == .profile && lens.correctsColorFringes && !lens.vignetting.isEmpty)
    }

    @Test func `falls back to the lens's display name`() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var spec = SyntheticLCP.Spec()
        spec.lens = "24.0-70.0 mm f/4.0"
        try write([spec])
        #expect(correction() != nil)
    }

    @Test func `the lens name the file reports wins over a display name`() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var byDisplayName = SyntheticLCP.Spec()
        byDisplayName.lens = "24.0-70.0 mm f/4.0"
        byDisplayName.vignette = nil
        try write([byDisplayName], to: "a.lcp")
        try write([SyntheticLCP.Spec()], to: "b.lcp")
        #expect(correction()?.vignetting.isEmpty == false)
    }

    @Test func `another lens, another maker's camera, or a profile made from JPEGs, gives no correction`() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var jpeg = SyntheticLCP.Spec()
        jpeg.lens = "NIKKOR Z 50mm f/1.8 S"
        jpeg.prettyName = "Nikon NIKKOR Z 50mm f/1.8 S"
        jpeg.focalLength = 50
        jpeg.raw = false
        try write([SyntheticLCP.Spec()])
        try write([jpeg], to: "Nikon/Z 6 50 JPEG.lcp")
        var info = Self.info
        info.cropFactor = 1
        info.lens = "NIKKOR Z 24-120mm f/4 S"
        #expect(correction(info) == nil)
        info.lens = "NIKKOR Z 50mm f/1.8 S"
        info.focalLength = 50
        #expect(correction(info) == nil)
        info = Self.info
        info.cropFactor = 1
        info.make = "Canon"
        #expect(correction(info) == nil)
        info = Self.info
        info.lens = nil
        #expect(correction(info) == nil)
    }

    @Test func `another body of the photo's make gets the profile from process 17, scaled to its sensor`() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var fullFrame = SyntheticLCP.Spec()
        fullFrame.sensorFormatFactor = 1
        try write([fullFrame])
        var info = Self.info
        info.model = "Z 7"
        #expect(correction(info) == nil, "without the photo's sensor size it can't be scaled")
        info.cropFactor = 1
        let lens = try #require(correction(info))
        #expect(lens.process == 17 && lens.profileProcess == 17 && lens.profileFolder == .redlamp)
        #expect(lens.profileCamera == "Nikon Z 6" && lens.profileName == "Nikon NIKKOR Z 24-70mm f/4 S")
        // The Z 7 has the Z 6's format: the profile applies as recorded, whatever the pixel count.
        #expect(try LCPProfileTests.difference(lens, #require(correction())) < 1e-9)
        var recipe = EditRecipe()
        recipe.processVersion = 16
        #expect(GeometryMap.profile(lens, recipe: recipe) == nil)
        recipe.processVersion = 17
        #expect(GeometryMap.profile(lens, recipe: recipe) != nil)
        // The photo's own body is matched as every process matches it.
        #expect(correction()?.process == 5 && correction()?.profileCamera == nil)

        // On an APS-C body the full-frame profile reaches only as far into the lens as its frame.
        info.model = "Z 50"
        info.cropFactor = 1.53
        let apsC = try #require(correction(info))
        #expect(try #require(apsC.vignetting.last) < lens.vignetting.last! && apsC.distortion.last!.y > lens.distortion
            .last!.y)
        // A profile made on a smaller sensor doesn't cover a larger one, unless it's within a tenth.
        var small = fullFrame
        small.sensorFormatFactor = 1.6
        try write([small])
        info.model = "Z 7"
        info.cropFactor = 1
        #expect(correction(info) == nil)
        info.cropFactor = 1.53
        #expect(correction(info) != nil, "Canon's APS-C, 22.3 mm wide, is within a tenth of others' 23.5 mm")
    }

    @Test func `the photo's own body comes first, then its make, then makes sharing its mount`() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        func profile(make: String, model: String, camera: String) -> SyntheticLCP.Spec {
            var spec = SyntheticLCP.Spec()
            (spec.make, spec.model, spec.cameraName) = (make, model, camera)
            spec.lens = "LUMIX S 24-105/F4 MACRO O.I.S."
            spec.prettyName = "Panasonic LUMIX S 24-105mm F4 MACRO O.I.S."
            spec.sensorFormatFactor = 1
            return spec
        }
        var info = Self.info
        (info.make, info.model, info.lens, info.cropFactor) = (
            "Panasonic",
            "DC-S5",
            "LUMIX S 24-105/F4 MACRO O.I.S.",
            1,
        )
        try write([profile(make: "SONY", model: "ILCE-7M3", camera: "Sony A7 III")], to: "a.lcp")
        #expect(correction(info) == nil, "Sony shares no mount with Panasonic")
        try write([profile(make: "SIGMA", model: "fp", camera: "Sigma fp")], to: "b.lcp")
        #expect(correction(info)?.profileCamera == "Sigma fp")
        try write([profile(make: "Panasonic", model: "DC-S1", camera: "Panasonic LUMIX DC-S1")], to: "c.lcp")
        #expect(correction(info)?.profileCamera == "Panasonic LUMIX DC-S1")
        try write([profile(make: "Panasonic", model: "DC-S5", camera: "Panasonic LUMIX DC-S5")], to: "d.lcp")
        #expect(correction(info).map { $0.profileCamera == nil && $0.process == 5 } == true)
        // Micro Four Thirds: an Olympus profile on a Panasonic G9, as OM System's on an Olympus.
        var olympus = profile(make: "OLYMPUS CORPORATION", model: "E-M1MarkII", camera: "Olympus OM-D E-M1 Mark II")
        olympus.lens = "OLYMPUS M.12-40mm F2.8"
        olympus.sensorFormatFactor = 2
        try write([olympus], to: "e.lcp")
        (info.model, info.lens, info.cropFactor) = ("DC-G9", "OLYMPUS M.12-40mm F2.8", 2)
        #expect(correction(info)?.profileCamera == "Olympus OM-D E-M1 Mark II")
        (info.make, info.model, info.canonicalMake, info.canonicalModel) = ("OM Digital", "OM-1", "Olympus", "OM-1")
        let omSystem = try #require(correction(info))
        #expect(omSystem.profileCamera == "Olympus OM-D E-M1 Mark II")
        // Olympus's own make, by LibRaw's canonical name: it's preferred to a make sharing the mount.
        var panasonic = olympus
        (panasonic.make, panasonic.model, panasonic.cameraName) = ("Panasonic", "DC-G9", "Panasonic LUMIX DC-G9")
        try write([panasonic], to: "0.lcp")
        #expect(correction(info)?.profileCamera == "Olympus OM-D E-M1 Mark II")
    }

    @Test func `a body sold under several names is the same body, by LibRaw's canonical name`() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var spec = SyntheticLCP.Spec()
        (spec.make, spec.model, spec.cameraName) = ("Canon", "Canon EOS 600D", "Canon EOS 600D")
        (spec.lens, spec.prettyName) = ("EF-S18-55mm f/3.5-5.6 IS II", "Canon EF-S 18-55mm f/3.5-5.6 IS II")
        spec.sensorFormatFactor = 1.6
        try write([spec])
        var info = Self.info
        (info.make, info.model, info.lens) = ("Canon", "EOS REBEL T3i", "EF-S18-55mm f/3.5-5.6 IS II")
        #expect(correction(info) == nil, "another body, and its sensor's size unknown")
        (info.canonicalMake, info.canonicalModel) = ("Canon", "EOS 600D")
        let lens = try #require(correction(info))
        #expect(lens.profileCamera == nil && lens.profileProcess == 17)
    }

    @Test func `the lens's other names match from process 17`() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var spec = SyntheticLCP.Spec()
        spec.alternateLensNames = ["24-70mm f/4"]
        try write([spec])
        var info = Self.info
        info.lens = "24-70mm f/4"
        let lens = try #require(correction(info))
        #expect(lens.profileProcess == 17 && lens.profileCamera == nil)
    }

    @Test func `a lens the file doesn't name is matched by its maker's number, where that names one lens`() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        func nikkor(_ lens: String, id: Int, focalLength: Double, range: String) -> SyntheticLCP.Spec {
            var spec = SyntheticLCP.Spec()
            (spec.model, spec.cameraName) = ("NIKON D3", "Nikon D3")
            (spec.lens, spec.prettyName, spec.lensID, spec.lensInfo) = (lens, "Nikon \(lens)", id, range)
            spec.focalLength = focalLength
            spec.sensorFormatFactor = 1
            return spec
        }
        try write([nikkor("105.0 mm f/2.8", id: 138, focalLength: 105, range: "105/1 105/1 28/10 28/10")], to: "a.lcp")
        try write([nikkor("105.0 mm f/1.4", id: 165, focalLength: 105, range: "105/1 105/1 14/10 14/10")], to: "b.lcp")
        try write([nikkor("35.0 mm f/1.8", id: 165, focalLength: 35, range: "35/1 35/1 18/10 18/10")], to: "c.lcp")
        var info = Self.info
        (info.model, info.lens, info.lensID, info.cropFactor) = ("D600", nil, 138, 1)
        info.focalLength = 105
        #expect(correction(info)?.profileName == "Nikon 105.0 mm f/2.8")
        info.lensID = 39
        #expect(correction(info) == nil)
        // 165 is two lenses: the lens's own focal lengths, where the maker note gives them, tell them apart.
        info.lensID = 165
        info.focalLength = 35
        info.lensFocalRange = 35 ... 35
        #expect(correction(info)?.profileName == "Nikon 35.0 mm f/1.8")
        try write(
            [nikkor("28.0-300.0 mm f/3.5-5.6", id: 165, focalLength: 35, range: "28/1 300/1 35/10 56/10")],
            to: "d.lcp",
        )
        #expect(correction(info)?.profileName == "Nikon 35.0 mm f/1.8")
        info.lensFocalRange = nil
        #expect(correction(info) == nil, "at 35 mm both the 35 mm and the 28-300 mm can be the lens")
        // Another maker's numbers say nothing about this camera's lenses.
        var canon = nikkor("105.0 mm f/2.8", id: 138, focalLength: 105, range: "105/1 105/1 28/10 28/10")
        (canon.make, canon.model) = ("Canon", "Canon EOS 5D Mark III")
        try FileManager.default.removeItem(at: directory)
        try write([canon], to: "e.lcp")
        (info.lensID, info.focalLength) = (138, 105)
        #expect(correction(info) == nil)
    }

    @Test func `Camera Raw's folders are read from process 17, after Redlamp's`() throws {
        let cameraRaw = directory.appending(path: "Camera Raw")
        let library = LCPProfileLibrary(folders: [
            .init(url: directory.appending(path: "Redlamp"), kind: .redlamp), .init(url: cameraRaw, kind: .cameraRaw),
        ])
        defer { try? FileManager.default.removeItem(at: directory) }
        var adobe = SyntheticLCP.Spec()
        adobe.vignette = nil
        try write([adobe], to: "Camera Raw/Nikon/Nikon Z 6 (NIKKOR Z 24-70mm f4 S) - RAW.lcp")
        let lens = try #require(correction(in: library))
        #expect(lens.profileFolder == .cameraRaw && lens.process == 17 && lens.vignetting.isEmpty)
        try write([SyntheticLCP.Spec()], to: "Redlamp/z6.lcp")
        let redlamp = try #require(correction(in: library))
        #expect(redlamp.profileFolder == .redlamp && redlamp.process == 5 && !redlamp.vignetting.isEmpty)
        #expect(library.issues.isEmpty)
    }

    @Test func `a Camera Raw folder is listed again when a folder in it changes`() throws {
        let cameraRaw = directory.appending(path: "Camera Raw")
        let library = LCPProfileLibrary(folders: [.init(url: cameraRaw, kind: .cameraRaw)])
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: cameraRaw.appending(path: "Nikon"),
            withIntermediateDirectories: true,
        )
        #expect(correction(in: library) == nil)
        let added = try write([SyntheticLCP.Spec()], to: "Camera Raw/Nikon/a.lcp")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 10)], ofItemAtPath: added.deletingLastPathComponent().path,
        )
        #expect(correction(in: library) != nil)
        try FileManager.default.removeItem(at: added)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 20)], ofItemAtPath: added.deletingLastPathComponent().path,
        )
        #expect(correction(in: library) == nil)
    }

    @Test func `a large Camera Raw file is read whole only once its first sub-profile names the photo's lens`(
    ) throws {
        let cameraRaw = directory.appending(path: "Camera Raw")
        let library = LCPProfileLibrary(folders: [.init(url: cameraRaw, kind: .cameraRaw)])
        defer { try? FileManager.default.removeItem(at: directory) }
        // Many settings of another lens, past the bytes read for the first: a broken tail would
        // fail a whole read, but not the first sub-profile's.
        var other = SyntheticLCP.Spec()
        (other.lens, other.prettyName) = ("NIKKOR Z 50mm f/1.8 S", "Nikon NIKKOR Z 50mm f/1.8 S")
        var data = SyntheticLCP.file(Array(repeating: other, count: 60))
        #expect(data.count > LCPProfileLibrary.firstBytes)
        data.append(Data("<broken".utf8))
        let url = cameraRaw.appending(path: "Nikon/50.lcp")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        try write([SyntheticLCP.Spec()], to: "Camera Raw/Nikon/24-70.lcp")
        #expect(correction(in: library) != nil)
        var info = Self.info
        info.lens = "NIKKOR Z 50mm f/1.8 S"
        info.focalLength = 50
        #expect(correction(info, in: library) == nil, "the 50 mm's file is read whole, and fails")
    }

    @Test func `a profile an edit names is found by file name or name, under Custom whatever its lens`() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var adapted = SyntheticLCP.Spec()
        (adapted.lens, adapted.prettyName, adapted.focalLength) = ("Helios 44-2 58mm f/2", "Helios 44-2 58mm f/2", 58)
        try write([adapted], to: "Helios.lcp")
        try write([SyntheticLCP.Spec()], to: "Z 6 24-70.lcp")
        let library = LCPProfileLibrary(directory: directory)
        func named(_ choice: LensProfileChoice, _ info: ImageInfo = Self.info) -> LensCorrection? {
            library.correction(
                named: choice,
                for: info,
                sensorSize: PixelSize(width: 6000, height: 4000),
                orientation: 0,
            )
        }
        let helios = "Synthetic (Helios 44-2 58mm f/2)"
        let custom = try #require(named(LensProfileChoice(setup: .custom, name: helios, fileName: "helios.LCP")))
        #expect(custom.profileFileName == "Helios.lcp" && custom.profileName == "Helios 44-2 58mm f/2")
        #expect(custom.profileProcess == nil && custom.profileFolder == .redlamp && custom.profileCamera == nil)
        #expect(named(LensProfileChoice(setup: .custom, name: helios))?.profileFileName == "Helios.lcp")
        // Default and Auto take a named profile only where it's of the photo's lens.
        #expect(named(LensProfileChoice(setup: .auto, name: helios, fileName: "Helios.lcp")) == nil)
        #expect(named(LensProfileChoice(setup: .defaults, fileName: "Z 6 24-70.lcp"))?
            .profileFileName == "Z 6 24-70.lcp")
        #expect(named(LensProfileChoice(setup: .custom, fileName: "Gone.lcp")) == nil)
        // A manual lens, which the file doesn't name, on another body of the same format.
        var manual = Self.info
        (manual.model, manual.lens, manual.focalLength, manual.cropFactor) = ("Z 7", nil, nil, nil)
        #expect(named(LensProfileChoice(setup: .custom, fileName: "Helios.lcp"), manual) == nil, "its sensor unknown")
        manual.cropFactor = 1
        adapted.sensorFormatFactor = 1
        try write([adapted], to: "Helios.lcp")
        let scaled = try #require(named(LensProfileChoice(setup: .custom, fileName: "Helios.lcp"), manual))
        #expect(scaled.profileCamera == "Nikon Z 6")
    }

    @Test func `the profiles a photo can be given by hand cover its sensor, by make, model and name`() throws {
        let library = LCPProfileLibrary(folders: [
            .init(url: directory.appending(path: "Redlamp"), kind: .redlamp),
            .init(url: directory.appending(path: "Camera Raw"), kind: .cameraRaw),
        ])
        defer { try? FileManager.default.removeItem(at: directory) }
        func lens(_ make: String, _ camera: String, _ lens: String, _ pretty: String, factor: Double?) -> SyntheticLCP
            .Spec {
            var spec = SyntheticLCP.Spec()
            (spec.make, spec.model, spec.cameraName) = (make, camera, camera)
            (spec.lens, spec.prettyName, spec.sensorFormatFactor) = (lens, pretty, factor)
            return spec
        }
        try write([SyntheticLCP.Spec()], to: "Redlamp/z6.lcp")
        try write([lens("SONY", "ILCE-7M3", "Batis 2/25", "Zeiss Batis 2/25", factor: 1)], to: "Camera Raw/Zeiss/b.lcp")
        try write(
            [lens(
                "Canon",
                "Canon EOS 5D Mark III",
                "EF24-70mm f/2.8L II USM",
                "Canon EF 24-70mm f/2.8L II USM",
                factor: 1,
            )],
            to: "Camera Raw/Canon/a.lcp",
        )
        try write(
            [lens("SONY", "ILCE-6400", "E 18-135mm", "Sony E 18-135mm", factor: 1.53)],
            to: "Camera Raw/Sony/c.lcp",
        )
        var jpeg = lens("SONY", "ILCE-7M3", "FE 85mm F1.8", "Sony FE 85mm F1.8", factor: 1)
        jpeg.raw = false
        try write([jpeg], to: "Camera Raw/Sony/d.lcp")
        var info = Self.info
        info.cropFactor = 1
        let options = library.options(for: info)
        #expect(options.map(\.make) == ["Canon", "Nikon", "Zeiss"])
        #expect(options.map(\.model) == [
            "Canon EF 24-70mm f/2.8L II USM", "Nikon NIKKOR Z 24-70mm f/4 S", "Zeiss Batis 2/25",
        ])
        #expect(options.map(\.folder) == [.cameraRaw, .redlamp, .cameraRaw])
        #expect(options[0].name == "Synthetic (Canon EF 24-70mm f/2.8L II USM)" && options[0].fileName == "a.lcp")
        info.cropFactor = 1.53
        #expect(library.options(for: info).count == 4, "an APS-C photo can take the APS-C profile too")
        info.cropFactor = nil
        #expect(library.options(for: info).map(\.make) == ["Nikon"], "without the photo's sensor size, its own body's")
    }

    @Test func `a correction the file carries wins over the user's profile`() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try write([SyntheticLCP.Spec()])
        let library = LCPProfileLibrary(directory: directory)
        let builtIn = LensCorrection(
            source: .sony, center: SIMD2(0.5, 0.5), radii: [0, 1], distortion: [], vignetting: [1, 1.5],
        )
        #expect(LensCorrectionReader
            .correction(for: Self.decoded(Self.info, lens: builtIn), profiles: library) == builtIn)
        #expect(LensCorrectionReader.correction(for: Self.decoded(Self.info, lens: nil), profiles: library)?
            .source == .profile)
        #expect(LensCorrectionReader.correction(for: Self.decoded(Self.info, lens: nil), profiles: nil) == nil)
        let bitmap = Self.decoded(Self.info, lens: nil, layout: .linearSRGBHalf)
        #expect(LensCorrectionReader.correction(for: bitmap, profiles: library) == nil)
    }

    @Test func `the profile corrections switch and its amounts govern the user's profile as a built-in one`() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try write([SyntheticLCP.Spec()])
        let lens = try #require(correction())
        var recipe = EditRecipe()
        #expect(GeometryMap.profile(lens, recipe: recipe) == lens.scaled(distortion: 1, vignetting: 1))
        #expect(!GeometryMap(recipe: recipe, imageSize: PixelSize(width: 6000, height: 4000), lens: lens).isIdentity)
        recipe[.lensProfileDistortion] = 50
        recipe[.lensProfileVignetting] = 0
        #expect(GeometryMap.profile(lens, recipe: recipe) == lens.scaled(distortion: 0.5, vignetting: 0))
        recipe[.lensProfile] = 0
        #expect(GeometryMap.profile(lens, recipe: recipe) == nil)
        recipe[.lensProfile] = 1
        recipe.processVersion = 4
        #expect(GeometryMap.profile(lens, recipe: recipe) == nil)
    }

    @Test func `profiles are read from subfolders, again when a file's date changes, and dropped when removed`() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try write([SyntheticLCP.Spec()])
        let modified = Date(timeIntervalSince1970: 1_790_000_000)
        func date(_ date: Date) throws {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        try date(modified)
        let library = LCPProfileLibrary(directory: directory)
        #expect(correction(in: library) != nil)
        var other = SyntheticLCP.Spec()
        other.lens = "NIKKOR Z 24-120mm f/4 S"
        other.prettyName = "Nikon NIKKOR Z 24-120mm f/4 S"
        try write([other])
        try date(modified)
        #expect(correction(in: library) != nil, "the same date: the profile already read")
        try date(modified + 10)
        #expect(correction(in: library) == nil, "a new date: read again")
        try write([SyntheticLCP.Spec()])
        try date(modified + 20)
        #expect(correction(in: library) != nil)
        try FileManager.default.removeItem(at: url)
        #expect(correction(in: library) == nil)
    }

    @Test func `a missing folder holds no profiles`() {
        let library = LCPProfileLibrary(directory: directory.appending(path: "Lens Profiles"))
        #expect(correction(in: library) == nil && library.issues.isEmpty)
    }

    @Test func `a fisheye profile corrects its lens from process 17, and a file that isn't a profile is reported`(
    ) throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var fisheye = SyntheticLCP.Spec()
        fisheye.fisheye = true
        try write([fisheye])
        try Data("<x:xmpmeta".utf8).write(to: directory.appending(path: "Nikon/broken.lcp"))
        let library = LCPProfileLibrary(directory: directory)
        let lens = try #require(correction(in: library))
        #expect(lens.profileProcess == 17 && lens.process == 17 && lens.profileFolder == .redlamp)
        #expect(library.issues.values.flatMap(\.self) == ["not an XML file"])
        // A rectilinear profile of the lens is the match every process makes, as before.
        try write([SyntheticLCP.Spec()], to: "Nikon/Z 6 24-70 rectilinear.lcp")
        let rectilinear = try #require(correction(in: LCPProfileLibrary(directory: directory)))
        #expect(rectilinear.profileProcess == nil && rectilinear.profileFileName == "Z 6 24-70 rectilinear.lcp")
    }

    // MARK: - Raw files

    private static func fixture(_ prefix: String) -> URL? {
        DecodeRegressionTests.fixtures.first { $0.lastPathComponent.hasPrefix(prefix) }
    }

    @Test(.enabled(if: !DecodeRegressionTests.fixtures.isEmpty))
    func `without a matching profile every photo opens with the correction it decoded with`() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var leica = SyntheticLCP.Spec()
        leica.make = "LEICA CAMERA AG"
        leica.model = "LEICA M11"
        leica.cameraName = "Leica M11"
        leica.lens = "Summilux-M 1:1.4/35 ASPH."
        leica.prettyName = "Leica Summilux-M 35mm f/1.4 ASPH."
        try write([leica], to: "Leica/M11 Summilux 35.lcp")
        let library = LCPProfileLibrary(directory: directory)
        for url in DecodeRegressionTests.fixtures {
            let image = try ImageDecoder.decode(url)
            let opened = LensCorrectionReader.correction(for: image, profiles: library)
            #expect(opened == (image.isRaw ? image.lensCorrection : nil), "\(url.lastPathComponent)")
        }
    }

    @Test(.enabled(if: fixture("DSC_0750") != nil && fixture("_DSC0009") != nil))
    func `a user's profile corrects a raw that carries none, and Sony's own correction wins`() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let nikon = try ImageDecoder.decode(#require(Self.fixture("DSC_0750")))
        let sony = try ImageDecoder.decode(#require(Self.fixture("_DSC0009")))
        var forNikon = SyntheticLCP.Spec()
        forNikon.lens = try #require(nikon.info.lens, "LibRaw names the Nikon's lens")
        forNikon.focalLength = nikon.info.focalLength ?? 24
        var forSony = SyntheticLCP.Spec()
        forSony.make = "SONY"
        forSony.model = "ILCE-7M3"
        forSony.cameraName = "Sony A7 III"
        forSony.lens = try #require(sony.info.lens, "LibRaw names the Sony's lens")
        forSony.focalLength = sony.info.focalLength ?? 24
        try write([forNikon], to: "nikon.lcp")
        try write([forSony], to: "sony.lcp")
        let library = LCPProfileLibrary(directory: directory)
        #expect(nikon.lensCorrection == nil)
        let corrected = try #require(LensCorrectionReader.correction(for: nikon, profiles: library))
        #expect(corrected.source == .profile && corrected.correctsColorFringes && !corrected.vignetting.isEmpty)
        #expect(LensCorrectionReader.correction(for: sony, profiles: library) == sony.lensCorrection)
        #expect(sony.lensCorrection?.source == .sony)
    }
}
