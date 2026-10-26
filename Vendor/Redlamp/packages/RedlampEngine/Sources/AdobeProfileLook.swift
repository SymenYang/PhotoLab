import Foundation
import Metal
import RedlampColor
import RedlampEngineAPI
import RedlampServices
import simd

/// One of the photographer's Adobe camera profiles as a Base Look (TON-51, TON-52): the profile's
/// calibration, which the develop kernel applies in place of the camera's, and its look, baked
/// into a scene-referred table. Nothing of it is stored: it renders while its files are on the Mac
/// (DEC-85).
struct AdobeProfileLook: Sendable {
    let reference: BaseLookReference
    let parameters: BaseLookParameters
    let calibration: ProfileCalibration
    /// Whether the table holds the look at the edit's Amount (an XMP look); otherwise the kernel
    /// mixes it with Redlamp's tone curve by Amount, as it does a DNG's own look.
    let amountInTable: Bool
    let bake: ProfileLookBake
}

/// A camera profile's matrices and HueSatMaps, which an Adobe look renders with in place of the
/// camera's (the develop kernel's process 4 path, at any process version). Immutable once made.
final class ProfileCalibration: @unchecked Sendable {
    let color: DNGColorCalibration
    let maps: HueSatMaps?

    init(_ dcp: DCPProfile, device: any MTLDevice) {
        color = dcp.color
        maps = HueSatMaps(profile: dcp.profile, device: device)
    }

    /// The profile's matrices with a DNG's own AnalogBalance, which belongs to the camera, not the profile.
    func color(for session: ImageSession) -> DNGColorCalibration {
        var color = color
        if let balance = session.dngColor?.analogBalance {
            color.analogBalance = balance
        }
        return color
    }

    /// The edit's colour temperature, by the profile's matrices when the edit keeps the camera's white balance.
    func temperature(for recipe: EditRecipe, session: ImageSession) -> Double {
        guard recipe.whiteBalanceMode == .asShot else { return recipe[.temperature] }
        let neutral = 1 / session.asShotMultipliers
        return color(for: session).temperature(ofNeutral: neutral / neutral.y)
    }

    func cameraToWorking(for recipe: EditRecipe, session: ImageSession) -> simd_float3x3 {
        color(for: session).cameraToWorking(temperature: temperature(for: recipe, session: session))
    }

    func hueSatWeight(for recipe: EditRecipe, session: ImageSession) -> Float {
        Float(color.weight(temperature(for: recipe, session: session)))
    }
}

/// A camera profile's look, with an XMP look over it, baked into a scene-referred table as
/// `EmbeddedLook` bakes a DNG's own profile's: scene light scaled by BaselineExposureOffset, the
/// profile's LookTable and the look's HSV table in linear ProPhoto, the profile's tone curve (or
/// Redlamp's, for a profile without one), the look's curve on sRGB-encoded values, and the look's
/// RGB table. An XMP look's parts follow Camera Raw's Profile Amount rules.
struct ProfileLookBake: Sendable {
    let base: DNGProfile
    let look: AdobeLook?

    /// Bumped when the bake changes; it is the looks' version, so edits made with another bake
    /// show their look as missing rather than rendering differently.
    static let version = 1
    static let tableSize = EmbeddedLook.tableSize

    /// Whether there is anything to bake: a profile of matrices and HueSatMaps alone renders with
    /// Redlamp's tone curve and no table.
    var hasTable: Bool {
        look != nil || base.lookTable != nil || base.toneCurve != nil
    }

    /// The table at `amount` percent (an XMP look's; a profile's own look is always whole).
    func table(amount: Double) -> LookTable? {
        guard hasTable else { return nil }
        let strength = look == nil ? 1 : min(max(amount / 100, 0), 2)
        let toProPhoto = HueSatMaps.workingToProPhoto
        let fromProPhoto = toProPhoto.inverse
        let gain = Float(exp2(base.baselineExposureOffset))
        let baseCurve = base.toneCurve.map(ToneSpline.init)
        let free: ClosedRange<Double> = 0 ... 2
        let hsv = look?.lookTable.flatMap { table -> DNGProfile.HSVMap? in
            let scale = Self.clamped(strength, to: look?.supportsAmount == true ? table.amounts : free)
            return scale > 0 ? Self.scaled(table.map, by: scale) : nil
        }
        let curve = strength > 0 ? look?.toneCurve.map { LookCurve(points: $0, amount: Float(strength)) } : nil
        let colors = look?.rgbTable.flatMap { table -> RGBTableMath? in
            let bounds = look?.supportsAmount == true ? table.amounts : free
            let amount = Self.clamped((look?.rgbTableAmount ?? 1) * strength, to: bounds)
            return amount > 0 ? RGBTableMath(table: table, amount: Float(amount)) : nil
        }
        let size = Self.tableSize
        var values = [Float16](repeating: 0, count: size * size * size * 3)
        values.withUnsafeMutableBufferPointer { buffer in
            // Each blue slice writes its own entries.
            nonisolated(unsafe) let out = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: size) { b in
                let scale = 1 / Float(size - 1)
                for g in 0 ..< size {
                    for r in 0 ..< size {
                        let encoded = SIMD3(Float(r), Float(g), Float(b)) * scale
                        var light = toProPhoto * (SceneLogEncoding.decode(encoded) * gain)
                        if let table = base.lookTable {
                            light = HSVMapMath.apply(table, to: light)
                        }
                        if let hsv {
                            light = HSVMapMath.apply(hsv, to: light)
                        }
                        var rec2020 = if let baseCurve {
                            fromProPhoto * baseCurve.rgbTone(light)
                        } else {
                            RedlampToneCurve.apply(fromProPhoto * light)
                        }
                        if let curve {
                            rec2020 = fromProPhoto * curve.apply(toProPhoto * rec2020)
                        }
                        if let colors {
                            rec2020 = colors.apply(rec2020)
                        }
                        let srgb = SIMD3(
                            SRGB.encode(max(rec2020.x, 0)),
                            SRGB.encode(max(rec2020.y, 0)),
                            SRGB.encode(max(rec2020.z, 0)),
                        )
                        let clamped = simd_clamp(
                            srgb,
                            SIMD3(repeating: 0),
                            SIMD3(repeating: LookTable.valueRange.upperBound),
                        )
                        let index = ((b * size + g) * size + r) * 3
                        out[index] = Float16(clamped.x)
                        out[index + 1] = Float16(clamped.y)
                        out[index + 2] = Float16(clamped.z)
                    }
                }
            }
        }
        return try? LookTable(size: size, space: .sceneLog, values: values)
    }

    static func clamped(_ value: Double, to bounds: ClosedRange<Double>) -> Double {
        min(max(value, bounds.lowerBound), bounds.upperBound)
    }

    /// A look table at a strength, as Camera Raw scales one: hue shifts in proportion, saturation and
    /// value scales from 1.
    static func scaled(_ map: DNGProfile.HSVMap, by strength: Double) -> DNGProfile.HSVMap {
        guard strength != 1 else { return map }
        let s = Float(strength)
        var scaled = map
        scaled.entries = map.entries.enumerated().map { index, value in
            index % 3 == 0 ? value * s : max(1 + (value - 1) * s, 0)
        }
        return scaled
    }
}

/// An XMP look's tone curve at a Profile Amount, as Camera Raw applies it: up to 100 mixed in from
/// no change, above it applied again at the excess, so 200 is the curve twice; on sRGB-encoded
/// values, the darkest and brightest channels through the curve and the others kept between them.
struct LookCurve: Sendable {
    let spline: ToneSpline
    let amount: Float

    init(points: [SIMD2<Float>], amount: Float) {
        spline = ToneSpline(points)
        self.amount = amount
    }

    func evaluate(_ x: Float) -> Float {
        let once = spline.evaluate(x)
        guard amount > 1 else { return x + (once - x) * amount }
        return once + (spline.evaluate(once) - once) * (amount - 1)
    }

    /// Linear values in, linear values out.
    func apply(_ linear: SIMD3<Float>) -> SIMD3<Float> {
        let clamped = simd_clamp(linear, .zero, SIMD3(repeating: 1))
        let encoded = SIMD3(SRGB.encode(clamped.x), SRGB.encode(clamped.y), SRGB.encode(clamped.z))
        let (low, high) = (encoded.min(), encoded.max())
        let (a, b) = (evaluate(low), evaluate(high))
        let out = high - low > 1e-8 ? a + (b - a) * (encoded - low) / (high - low) : SIMD3(repeating: a)
        return SIMD3(SRGB.decode(out.x), SRGB.decode(out.y), SRGB.decode(out.z))
    }
}

/// An Adobe RGB table applied as the DNG SDK applies one: into its primaries and encoding, clipped
/// into its range (what clipping took added back afterwards when it extends the gamut), through
/// the table, tetrahedrally for a 3D one, and moved `amount` of the way from the input.
struct RGBTableMath: Sendable {
    let table: AdobeRGBTable
    let amount: Float
    private let into: simd_float3x3
    private let back: simd_float3x3

    init(table: AdobeRGBTable, amount: Float) {
        self.table = table
        self.amount = amount
        let space: simd_float3x3 = switch table.primaries {
        case .sRGB: ColorMatrices.rec2020ToSRGB.floatMatrix
        case .adobeRGB: RGBPrimaries.rec2020.conversion(to: .adobeRGB).floatMatrix
        case .proPhoto: HueSatMaps.workingToProPhoto
        }
        into = space
        back = space.inverse
    }

    /// Linear Rec.2020 in and out.
    func apply(_ rec2020: SIMD3<Float>) -> SIMD3<Float> {
        let linear = into * rec2020
        let full = SIMD3(encode(linear.x), encode(linear.y), encode(linear.z))
        let encoded = simd_clamp(full, .zero, SIMD3(repeating: 1))
        let looked = lookup(encoded)
        var out = encoded + amount * (looked - encoded)
        if table.extendsGamut {
            out += full - encoded
        }
        return back * SIMD3(decode(out.x), decode(out.y), decode(out.z))
    }

    private func encode(_ value: Float) -> Float {
        let magnitude = abs(value)
        let encoded: Float = switch table.encoding {
        case .linear: magnitude
        case .sRGB: SRGB.encode(magnitude)
        case .gamma18: pow(magnitude, 1 / 1.8)
        case .gamma22: pow(magnitude, 1 / 2.2)
        }
        return value < 0 ? -encoded : encoded
    }

    private func decode(_ value: Float) -> Float {
        let magnitude = abs(value)
        let decoded: Float = switch table.encoding {
        case .linear: magnitude
        case .sRGB: SRGB.decode(magnitude)
        case .gamma18: pow(magnitude, 1.8)
        case .gamma22: pow(magnitude, 2.2)
        }
        return value < 0 ? -decoded : decoded
    }

    private func sample(_ index: Int) -> SIMD3<Float> {
        SIMD3(table.samples[index * 3], table.samples[index * 3 + 1], table.samples[index * 3 + 2])
    }

    private func lookup(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let n = table.divisions
        let scaled = rgb * Float(n - 1)
        let cell = SIMD3<Int>(min(Int(scaled.x), n - 2), min(Int(scaled.y), n - 2), min(Int(scaled.z), n - 2))
        let f = scaled - SIMD3<Float>(cell)
        guard table.isThreeDimensional else {
            var out = SIMD3<Float>.zero
            for channel in 0 ..< 3 {
                let low = sample(cell[channel])[channel], high = sample(cell[channel] + 1)[channel]
                out[channel] = low + (high - low) * f[channel]
            }
            return out
        }
        func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> {
            sample(((cell.x + r) * n + cell.y + g) * n + cell.z + b)
        }
        // Six tetrahedra along the cell's grey diagonal, picked by the order of the fractions.
        let c000 = at(0, 0, 0), c111 = at(1, 1, 1)
        let (first, second, weights): (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
        if f.x > f.y {
            if f.y > f.z {
                (first, second, weights) = (at(1, 0, 0), at(1, 1, 0), SIMD3(f.x, f.y, f.z))
            } else if f.x > f.z {
                (first, second, weights) = (at(1, 0, 0), at(1, 0, 1), SIMD3(f.x, f.z, f.y))
            } else {
                (first, second, weights) = (at(0, 0, 1), at(1, 0, 1), SIMD3(f.z, f.x, f.y))
            }
        } else if f.z > f.y {
            (first, second, weights) = (at(0, 0, 1), at(0, 1, 1), SIMD3(f.z, f.y, f.x))
        } else if f.z > f.x {
            (first, second, weights) = (at(0, 1, 0), at(0, 1, 1), SIMD3(f.y, f.z, f.x))
        } else {
            (first, second, weights) = (at(0, 1, 0), at(1, 1, 0), SIMD3(f.y, f.x, f.z))
        }
        return c000 + weights.x * (first - c000) + weights.y * (second - first) + weights.z * (c111 - second)
    }
}

/// The photographer's Adobe camera profiles for each camera the engine has opened, as Base Looks
/// (TON-51, TON-52). A camera's profiles are listed when first asked for, and again when the menu
/// asks; calibrations are made once for each profile.
final class CameraProfileLooks: @unchecked Sendable {
    struct Entry: Sendable {
        let look: AdobeProfileLook
        let descriptor: CameraProfileLook
    }

    let library: CameraProfileLibrary
    private let device: any MTLDevice
    private let lock = NSLock()
    /// Each camera's looks, and the library's revision they were found at: another engine sharing
    /// the library may have chosen files since.
    private var cameras: [String: (revision: Int, entries: [Entry])] = [:]
    private var calibrations: [String: ProfileCalibration] = [:]

    init(library: CameraProfileLibrary, device: any MTLDevice) {
        self.library = library
        self.device = device
    }

    /// The looks for a camera: those found last unless `refresh`, which lists the folders again,
    /// and those found before that aren't any more.
    func looks(make: String?, model: String?, refresh: Bool) -> (found: [Entry], gone: [BaseLookReference]) {
        guard let make, let model else { return ([], []) }
        let key = "\(make)\u{1F}\(model)"
        let revision = library.revision
        if !refresh, let cached = lock.withLock({ cameras[key] }), cached.revision == revision {
            return (cached.entries, [])
        }
        let entries = entries(for: library.profiles(make: make, model: model))
        let before = lock.withLock {
            defer { cameras[key] = (revision, entries) }
            return cameras[key]?.entries ?? []
        }
        let ids = Set(entries.map(\.look.reference.id))
        return (entries, before.map(\.look.reference).filter { !ids.contains($0.id) })
    }

    private func calibration(_ dcp: DCPProfile) -> ProfileCalibration {
        lock.withLock {
            if let made = calibrations[dcp.identity] {
                return made
            }
            let made = ProfileCalibration(dcp, device: device)
            calibrations[dcp.identity] = made
            return made
        }
    }

    private func entries(for found: CameraProfileLibrary.Found) -> [Entry] {
        var entries: [Entry] = []
        for profile in found.profiles {
            let reference = BaseLookReference(
                id: BaseLookReference.adobeIDPrefix + profile.dcp.identity, version: ProfileLookBake.version,
                name: profile.dcp.name,
            )
            entries.append(Entry(
                look: AdobeProfileLook(
                    reference: reference, parameters: .identity, calibration: calibration(profile.dcp),
                    amountInTable: false, bake: ProfileLookBake(base: profile.dcp.profile, look: nil),
                ),
                descriptor: CameraProfileLook(
                    reference: reference, group: Self.group(profile.source, look: nil),
                    summary: Self.summary(profile),
                ),
            ))
        }
        for item in found.looks {
            let look = item.look
            // A look goes over its base: without the camera's Adobe Standard there is nothing to put it on.
            guard let base = found.base(for: look) else { continue }
            let reference = BaseLookReference(
                id: BaseLookReference.adobeIDPrefix + base.dcp.identity + "/" + look.identity,
                version: ProfileLookBake.version, name: look.name,
            )
            let parameters = look.convertsToGrayscale
                ? BaseLookParameters(contrast: 1, saturation: 1, warmth: 0, isMonochrome: true) : .identity
            entries.append(Entry(
                look: AdobeProfileLook(
                    reference: reference, parameters: parameters, calibration: calibration(base.dcp),
                    amountInTable: true, bake: ProfileLookBake(base: base.dcp.profile, look: look),
                ),
                descriptor: CameraProfileLook(
                    reference: reference, group: Self.group(item.source, look: look),
                    summary: Self.summary(item, base: base.dcp), isMonochrome: look.convertsToGrayscale,
                    leftOut: look.leftOut,
                ),
            ))
        }
        return entries.sorted { Self.order($0.descriptor) < Self.order($1.descriptor) }
    }

    private static func group(_ source: CameraProfileLibrary.Source, look: AdobeLook?) -> CameraProfileLook.Group {
        switch source {
        case .adobeRaw: .adobeRaw
        case .cameraMatching: .cameraMatching
        case .creative: .creative(look?.group ?? "Creative")
        case .own: .own(look?.group)
        }
    }

    /// The menu's order: Adobe Raw, Camera Matching, the creative groups, the photographer's own;
    /// by name within each.
    private static func order(_ look: CameraProfileLook) -> (Int, String, String) {
        switch look.group {
        case .adobeRaw: (0, "", look.reference.name)
        case .cameraMatching: (1, "", look.reference.name)
        case let .creative(group): (2, group, look.reference.name)
        case let .own(group): (3, group ?? "", look.reference.name)
        }
    }

    private static let policies = [
        "allows copying",
        "may be embedded where it's used",
        "is never to be embedded",
        "has no restrictions",
    ]

    private static func summary(_ profile: CameraProfileLibrary.Profile) -> String {
        let whose = profile.source == .own ? "A camera profile" : "Adobe's camera profile"
        var text = "\(whose) for the \(profile.dcp.cameraModel), read from \(profile.url.deletingLastPathComponent().path)."
        if let policy = profile.dcp.embedPolicy, policies.indices.contains(policy) {
            text += " Its embed policy \(policies[policy]); Redlamp never copies or embeds it."
        }
        return text
    }

    private static func summary(_ found: CameraProfileLibrary.Look, base: DCPProfile) -> String {
        let whose = found.look.cluster == "Adobe" ? "Adobe's look" : "A look"
        var text = "\(whose) over the camera's \(base.name), read from \(found.url.deletingLastPathComponent().path)."
        if !found.look.leftOut.isEmpty {
            text += " Redlamp leaves out what it sets besides its tables: \(found.look.leftOut.joined(separator: ", "))."
        }
        return text
    }
}
