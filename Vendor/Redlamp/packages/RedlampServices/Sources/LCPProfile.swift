import Foundation

/// An Adobe lens profile (an LCP file) the user supplies, read with Redlamp's own reader (LNS-04);
/// Adobe's files are never shipped or converted. The format and its models are the Adobe Camera
/// Model's (S. Chen, H. Jin, J. Chien, E. Chan and D. Goldman, Adobe technical report 1.0, 2010): an
/// XMP file listing sub-profiles, each one camera and lens at one focal length, aperture and focus
/// distance, with a rectilinear or fisheye geometric distortion model, a lateral chromatic
/// aberration model and a vignette model, their parameters normalised by the image's larger side.
struct LCPProfile: Sendable {
    /// One camera and lens at one setting.
    struct SubProfile: Sendable, Equatable {
        var make: String
        var model: String?
        var uniqueCameraModel: String?
        var cameraPrettyName: String?
        /// The lens as the reference photos' metadata names it.
        var lens: String?
        /// Other names the lens's metadata gives it, on other bodies or firmware.
        var alternateLensNames: [String] = []
        /// The lens as the profile's author names it.
        var lensPrettyName: String?
        /// The maker's number for the lens (Nikon's LensIDNumber in Adobe's Nikon profiles).
        var lensID: Int?
        /// The lens's focal lengths in millimetres, from its LensInfo.
        var lensFocalRange: ClosedRange<Double>?
        var profileName: String?
        /// Millimetres.
        var focalLength: Double
        /// APEX: twice the base-2 logarithm of the f-number.
        var apertureValue: Double
        /// Metres.
        var focusDistance: Double?
        var sensorFormatFactor: Double?
        /// The reference photos' width and height in pixels.
        var imageSize: SIMD2<Double>?
        /// Made from raw photos for raw photos, rather than from JPEG or TIFF.
        var isRaw: Bool
        /// The geometric models take the fisheye form (`FisheyeModel`, LNS-17).
        var isFisheye = false
        /// The geometric distortion model, rectilinear or fisheye.
        var distortion: Model?
        var chromatic: Chromatic?
        var vignette: Model?
    }

    /// The lateral chromatic aberration model: green's geometric distortion, and where red and
    /// blue are recorded relative to green's recorded point.
    struct Chromatic: Sendable, Equatable {
        var green: Model
        var red: Model
        var blue: Model
    }

    /// One model's descriptors, as the file gives them.
    struct Model: Sendable, Equatable {
        /// fx and fy over the image's larger side; nil to derive them from the focal length.
        var focalLength: SIMD2<Double>?
        /// u₀ and v₀ over the image's larger side; nil for the image's centre.
        var centerX: Double?
        var centerY: Double?
        /// α₀ or β₀ for the differential colour models; 1 elsewhere.
        var scale: Double
        /// The coefficients of r², r⁴ and r⁶: k₁ to k₃, or the vignette's α₁ to α₃.
        var radial: SIMD3<Double>
        /// k₄ and k₅, read but not applied: they don't fit a radial table.
        var tangential: SIMD2<Double>
    }

    var subProfiles: [SubProfile]
    /// Sub-profiles left out, each with the reason.
    var skipped: [String]
}

extension LCPProfile {
    struct ReadError: Error, CustomStringConvertible {
        var description: String
    }

    static let photoshop = "http://ns.adobe.com/photoshop/1.0/"
    static let stCamera = "http://ns.adobe.com/photoshop/1.0/camera-profile"

    /// The sub-profiles are the items of `photoshop:CameraProfiles`. With `firstOnly`, reading stops
    /// after the first, which names the camera and lens as every other does: a profile describes
    /// one camera and lens.
    init(data: Data, firstOnly: Bool = false) throws {
        guard let resources = LCPResource.read(
            data, stoppingAfterFirstItemOf: firstOnly ? (name: "CameraProfiles", namespace: Self.photoshop) : nil,
        ) else { throw ReadError(description: "not an XML file") }
        let items = resources.flatMap { $0.resources(under: "CameraProfiles", in: Self.photoshop) }
        guard !items.isEmpty else { throw ReadError(description: "no camera profiles") }
        var subProfiles: [SubProfile] = []
        var skipped: [String] = []
        for item in items {
            switch SubProfile.read(item) {
            case let .success(subProfile): subProfiles.append(subProfile)
            case let .failure(error): skipped.append(error.description)
            }
        }
        self.init(subProfiles: subProfiles, skipped: skipped)
    }
}

extension LCPProfile.SubProfile {
    /// The name to show for the profile.
    var name: String {
        profileName ?? lensPrettyName ?? lens ?? make
    }

    /// The shortest and longest focal lengths of an EXIF LensInfo written out, `24/1 70/1 28/10 28/10`.
    static func focalRange(_ lensInfo: String) -> ClosedRange<Double>? {
        let values = lensInfo.split(whereSeparator: \.isWhitespace).prefix(2).map { value -> Double? in
            let parts = value.split(separator: "/", maxSplits: 1).map { Double($0) }
            guard let numerator = parts.first ?? nil else { return nil }
            guard parts.count == 2 else { return numerator }
            return parts[1].flatMap { $0 > 0 ? numerator / $0 : nil }
        }
        guard values.count == 2, let shortest = values[0], let longest = values[1], shortest > 0, longest >= shortest
        else { return nil }
        return shortest ... longest
    }

    static func read(_ item: LCPResource) -> Result<Self, LCPProfile.ReadError> {
        let label = (item.string("ProfileName") ?? item.string("LensPrettyName") ?? item.string("Lens") ?? "A profile")
            + (item.number("FocalLength").map { " at \($0.formatted()) mm" } ?? "")
        func skip(_ reason: String) -> Result<Self, LCPProfile.ReadError> {
            .failure(LCPProfile.ReadError(description: "\(label): \(reason)"))
        }
        let perspective = item.resource("PerspectiveModel")
        let fisheye = perspective == nil ? item.resource("FisheyeModel") : nil
        let geometric = perspective ?? fisheye
        guard let make = item.string("Make") else { return skip("no camera make") }
        guard let focalLength = item.number("FocalLength"), focalLength > 0 else { return skip("no focal length") }
        guard let apertureValue = item.number("ApertureValue") else { return skip("no aperture") }
        /// Adobe's files nest the colour and vignette models in the geometric model.
        func nested(_ name: String, coefficients: String = "RadialDistortParam") -> LCPProfile.Model? {
            LCPProfile.Model(geometric?.resource(name) ?? item.resource(name), coefficients: coefficients)
        }
        let distortion = LCPProfile.Model(geometric, coefficients: "RadialDistortParam")
        var chromatic: LCPProfile.Chromatic?
        if let green = nested("ChromaticGreenModel") ?? distortion, let red = nested("ChromaticRedGreenModel"),
           let blue = nested("ChromaticBlueGreenModel") {
            chromatic = LCPProfile.Chromatic(green: green, red: red, blue: blue)
        }
        let vignette = nested("VignetteModel", coefficients: "VignetteModelParam")
        guard distortion != nil || chromatic != nil || vignette != nil else {
            return skip("no lens model")
        }
        let (width, length) = (item.number("ImageWidth"), item.number("ImageLength"))
        return .success(Self(
            make: make,
            model: item.string("Model"),
            uniqueCameraModel: item.string("UniqueCameraModel"),
            cameraPrettyName: item.string("CameraPrettyName"),
            lens: item.string("Lens"),
            alternateLensNames: item.strings("AlternateLensNames"),
            lensPrettyName: item.string("LensPrettyName"),
            lensID: item.string("LensID").flatMap { Int($0) },
            lensFocalRange: item.string("LensInfo").flatMap(Self.focalRange),
            profileName: item.string("ProfileName"),
            focalLength: focalLength,
            apertureValue: apertureValue,
            focusDistance: item.number("FocusDistance"),
            sensorFormatFactor: item.number("SensorFormatFactor"),
            imageSize: width.flatMap { width in length.map { SIMD2(width, $0) } },
            isRaw: item.string("CameraRawProfile")?.lowercased() != "false",
            isFisheye: fisheye != nil,
            distortion: distortion,
            chromatic: chromatic,
            vignette: vignette,
        ))
    }
}

extension LCPProfile.Model {
    /// `coefficients` names the polynomial's descriptors (`RadialDistortParam` or
    /// `VignetteModelParam`); nil without the first of them or a scale factor.
    init?(_ resource: LCPResource?, coefficients prefix: String) {
        guard let resource else { return nil }
        let (k1, scale) = (resource.number(prefix + "1"), resource.number("ScaleFactor"))
        guard k1 != nil || scale != nil else { return nil }
        let (fx, fy) = (resource.number("FocalLengthX"), resource.number("FocalLengthY"))
        self.init(
            focalLength: (fx ?? fy).map { SIMD2($0, fy ?? $0) },
            centerX: resource.number("ImageXCenter"),
            centerY: resource.number("ImageYCenter"),
            scale: scale ?? 1,
            radial: SIMD3(k1 ?? 0, resource.number(prefix + "2") ?? 0, resource.number(prefix + "3") ?? 0),
            tangential: SIMD2(
                resource.number("TangentialDistortParam1") ?? 0, resource.number("TangentialDistortParam2") ?? 0,
            ),
        )
    }
}

// MARK: - Matching

extension LCPProfile.SubProfile {
    /// How a photo's lens matches a sub-profile's, weakest first. `lensMatch` gives the three every
    /// process uses; process 17 adds another name the lens goes by and the maker's number for it.
    enum LensMatch: Comparable {
        case unmatched, lensID, alternate, prettyName, lens
    }

    /// Whether this is the photo's camera. EXIF's names (`NIKON CORPORATION`, `NIKON Z 6`) and
    /// LibRaw's (`Nikon`, `Z 6`) agree once case, spaces and the make inside the model are set aside.
    func matchesCamera(make photoMake: String, model photoModel: String?) -> Bool {
        let (ours, theirs) = (Self.makeKey(photoMake), Self.makeKey(make))
        let names = [model, uniqueCameraModel, cameraPrettyName].compactMap(\.self)
        guard !ours.isEmpty else { return false }
        guard !names.isEmpty else { return ours == theirs }
        guard let photoModel else { return false }
        let wanted = Self.key(photoModel, dropping: [ours])
        return names.contains { name in
            (ours == theirs || Self.key(name).hasPrefix(ours)) && Self.key(name, dropping: [theirs, ours]) == wanted
        }
    }

    /// How the photo's lens matches: by the name the reference photos' metadata gives it, by the
    /// profile's display name for it, or not at all.
    func lensMatch(_ photoLens: String, make photoMake: String) -> LensMatch {
        let makes = [Self.makeKey(photoMake)]
        let wanted = Self.key(photoLens, dropping: makes)
        guard !wanted.isEmpty else { return .unmatched }
        if let lens, Self.key(lens, dropping: makes) == wanted {
            return .lens
        }
        if let lensPrettyName, Self.key(lensPrettyName, dropping: makes) == wanted {
            return .prettyName
        }
        return .unmatched
    }

    /// A name in lower case without spaces, less a leading make.
    static func key(_ name: String, dropping makes: [String] = []) -> String {
        let key = name.lowercased().filter { !$0.isWhitespace }
        for make in makes where !make.isEmpty && key.count > make.count && key.hasPrefix(make) {
            return String(key.dropFirst(make.count))
        }
        return key
    }

    /// A make's first word in lower case: `NIKON CORPORATION` and `Nikon` are both `nikon`.
    static func makeKey(_ make: String) -> String {
        make.lowercased().split { !$0.isLetter && !$0.isNumber }.first.map(String.init) ?? ""
    }
}

private extension LCPResource {
    func string(_ name: String) -> String? {
        guard case let .literal(text)? = value(name, in: LCPProfile.stCamera) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func number(_ name: String) -> Double? {
        string(name).flatMap { Double($0) }.flatMap { $0.isFinite ? $0 : nil }
    }

    /// The literal items of a list property (`rdf:Seq`, `rdf:Bag` or `rdf:Alt`).
    func strings(_ name: String) -> [String] {
        guard case let .list(items)? = value(name, in: LCPProfile.stCamera) else { return [] }
        return items.compactMap { item in
            guard case let .literal(text) = item else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    func resource(_ name: String) -> LCPResource? {
        guard case let .resource(resource)? = value(name, in: LCPProfile.stCamera) else { return nil }
        return resource
    }
}
