import Foundation
import simd

/// A lens correction the photo carries (LNS-01, LNS-02): every source, whether DNG warp opcodes or
/// a maker's correction tags, as the same tables over the distance from the optical centre.
///
/// Positions are in the EXIF-oriented photo. A radius of 1 is the farthest corner from the
/// centre (the DNG specification's normalisation, which for a centred lens is the half-diagonal).
public struct LensCorrection: Codable, Sendable, Hashable {
    public enum Source: String, Codable, Sendable {
        /// The DNG's OpcodeList3 (WarpRectilinear, FixVignetteRadial), as phones write them.
        case dng
        /// Sony's correction tags in the ARW, the camera's own built-in profile.
        case sony
        /// Fujifilm's correction tags in the RAF.
        case fujifilm
        /// Panasonic's correction tags in the RW2 (and Leica's RWL, which Panasonic makes).
        case panasonic
        /// Olympus's and OM System's correction tags in the ORF.
        case omSystem
        /// Measured from the photo's own edges (Remove Chromatic Aberration).
        case measured
        /// A lens profile the user supplied (an Adobe LCP file, LNS-04), for a raw that carries none.
        case profile

        public var name: String {
            switch self {
            case .dng: "DNG"
            case .sony: "Sony"
            case .fujifilm: "Fujifilm"
            case .panasonic: "Panasonic"
            case .omSystem: "OM System"
            case .measured: "Measured"
            case .profile: "lens profile"
            }
        }

        /// The first process version that applies corrections from this source.
        public var process: Int {
            switch self {
            case .fujifilm: 6
            case .panasonic, .omSystem: 16
            case .dng, .sony, .measured, .profile: 5
            }
        }
    }

    public var source: Source
    /// The optical centre, 0...1.
    public var center: SIMD2<Double>
    /// Radii of the table entries, increasing, starting at or below 0.
    public var radii: [Double]
    /// Per radius of the corrected photo: where each of red, green and blue was recorded, as a
    /// multiple of the radius. Empty without distortion correction.
    public var distortion: [SIMD3<Double>]
    /// Per radius of the recorded photo: the gain that undoes the lens's vignetting. Empty
    /// without vignetting correction.
    public var vignetting: [Double]
    /// The lens a user's profile names, which the Lens panel shows (LNS-11); nil for a correction
    /// the file carries. Only a label: the correction renders the same without it.
    public var profileName: String?
    /// The folder a lens profile was found in (LNS-16), its file's name (LNS-15), and the camera it
    /// was made on where that's another than the photo's (LNS-14). Only labels.
    public var profileFolder: LensProfileFolder?
    public var profileFileName: String?
    public var profileCamera: String?
    /// The first process version whose matching finds this lens profile, where it's later than its
    /// source's: process 17 matches profiles made on other bodies and those in Camera Raw's folders.
    public var profileProcess: Int?

    /// The first process version that applies the correction.
    public var process: Int {
        max(source.process, profileProcess ?? 0)
    }

    public init(
        source: Source, center: SIMD2<Double>, radii: [Double], distortion: [SIMD3<Double>], vignetting: [Double],
        profileName: String? = nil,
    ) {
        self.source = source
        self.center = center
        self.radii = radii
        self.distortion = distortion
        self.vignetting = vignetting
        self.profileName = profileName
    }

    /// What `interpolate` relies on: at least two finite, increasing radii, and tables empty or
    /// one finite entry per radius, about a finite centre.
    public var isValid: Bool {
        radii.count >= 2 && radii.allSatisfy(\.isFinite) && zip(radii, radii.dropFirst()).allSatisfy { $0 < $1 }
            && [0, radii.count].contains(distortion.count) && [0, radii.count].contains(vignetting.count)
            && distortion.allSatisfy { ($0 * 0).sum() == 0 } && vignetting.allSatisfy(\.isFinite)
            && (center * 0).sum() == 0
    }

    /// Whether red and blue are recorded at another scale than green (lateral chromatic aberration).
    public var correctsColorFringes: Bool {
        distortion.contains { abs($0.x - $0.y) > 1e-7 || abs($0.z - $0.y) > 1e-7 }
    }

    /// Linear interpolation of a table over `radii`, holding the ends.
    public func interpolate<T: SIMD>(_ values: [T], at radius: Double) -> T where T.Scalar == Double {
        guard let first = values.first else { return T(repeating: 1) }
        guard radius > radii[0] else { return first }
        for index in 1 ..< min(radii.count, values.count) where radius <= radii[index] {
            let t = (radius - radii[index - 1]) / (radii[index] - radii[index - 1])
            return values[index - 1] + (values[index] - values[index - 1]) * T(repeating: t)
        }
        return values[min(radii.count, values.count) - 1]
    }

    public func interpolate(_ values: [Double], at radius: Double) -> Double {
        interpolate(values.map { SIMD2(repeating: $0) }, at: radius).x
    }

    /// The same correction at a strength: distortion's departure from 1 and vignetting's gain in
    /// stops scale with the amounts (1 as recorded).
    public func scaled(distortion distortionAmount: Double, vignetting vignettingAmount: Double) -> LensCorrection {
        var scaled = self
        scaled.distortion = distortion.map { 1 + ($0 - 1) * distortionAmount }
        scaled.vignetting = vignetting.map { pow(max($0, 1e-4), vignettingAmount) }
        return scaled
    }

    /// The correction scaled up just enough that the corrected frame stays inside the photo, as
    /// Lightroom's profile corrections do: a correction that pulls the edges in (pincushion)
    /// would otherwise leave the corners empty. The zoom folds into the distortion table.
    public func filling(imageSize: PixelSize) -> LensCorrection {
        guard !distortion.isEmpty else { return self }
        let scale = offsetScale(imageSize: imageSize)
        let border = (0 ... 16).flatMap { index -> [SIMD2<Double>] in
            let t = Double(index) / 16
            return [SIMD2(t, 0), SIMD2(t, 1), SIMD2(0, t), SIMD2(1, t)]
        }
        func fits(_ zoom: Double) -> Bool {
            border.allSatisfy { point in
                let offset = (point - center) / zoom
                let source = center + offset * interpolate(distortion, at: simd_length(offset * scale)).y
                return source.min() >= -1e-6 && source.max() <= 1 + 1e-6
            }
        }
        guard !fits(1) else { return self }
        var (low, high) = (1.0, 1.5)
        for _ in 0 ..< 40 {
            let middle = (low + high) / 2
            if fits(middle) {
                high = middle
            } else {
                low = middle
            }
        }
        var zoomed = self
        zoomed.distortion = radii.map { interpolate(distortion, at: $0 / high) / high }
        return zoomed
    }

    /// Photo coordinates (0...1) to the lens's normalised offset from the centre, for a photo of `size`.
    public func offsetScale(imageSize size: PixelSize) -> SIMD2<Double> {
        let (w, h) = (Double(size.width), Double(size.height))
        let reach = SIMD2(max(center.x, 1 - center.x) * w, max(center.y, 1 - center.y) * h)
        return SIMD2(w, h) / simd_length(reach)
    }
}

/// Where lens profiles are kept (LNS-04, LNS-16).
public enum LensProfileFolder: String, Codable, Sendable, CaseIterable {
    /// Redlamp's Lens Profiles folder, in Application Support.
    case redlamp
    /// The photographer's own Camera Raw lens profiles, in `~/Library/Application
    /// Support/Adobe/CameraRaw/LensProfiles`.
    case cameraRawUser
    /// The lens profiles Lightroom Classic and Camera Raw install, in
    /// `/Library/Application Support/Adobe/CameraRaw/LensProfiles/1.0`.
    case cameraRaw

    /// The folder in a sentence: "a lens profile in …".
    public var name: String {
        switch self {
        case .redlamp: "your Lens Profiles folder"
        case .cameraRawUser: "your Camera Raw lens profiles"
        case .cameraRaw: "Camera Raw's lens profiles"
        }
    }

    /// The folder in a few words, as the Lens panel labels a profile.
    public var shortName: String {
        switch self {
        case .redlamp: "Redlamp"
        case .cameraRawUser: "your Camera Raw"
        case .cameraRaw: "Camera Raw"
        }
    }
}

public extension LensCorrection {
    /// DNG WarpRectilinear coefficients (one set per plane, or one for all), tabulated: the source
    /// radius is f(r)·r with f = kr0 + kr1 r² + kr2 r⁴ + kr3 r⁶. Tangential terms are left out:
    /// they don't survive a radial table, and phones write them as zero.
    static func tabulated(warp planes: [SIMD4<Double>], vignette: [Double]?, center: SIMD2<Double>) -> LensCorrection {
        let radii = (0 ... 32).map { Double($0) / 32 * 1.05 }
        func f(_ k: SIMD4<Double>, _ r: Double) -> Double {
            let r2 = r * r
            return k.x + k.y * r2 + k.z * r2 * r2 + k.w * r2 * r2 * r2
        }
        let distortion = planes.isEmpty ? [] : radii.map { r -> SIMD3<Double> in
            planes.count >= 3 ? SIMD3(f(planes[0], r), f(planes[1], r), f(planes[2], r)) : SIMD3(repeating: f(
                planes[0],
                r,
            ))
        }
        let vignetting = vignette.map { k in
            radii.map { r -> Double in
                let r2 = r * r
                return 1 + k[0] * r2 + k[1] * pow(r2, 2) + k[2] * pow(r2, 3) + k[3] * pow(r2, 4) + k[4] * pow(r2, 5)
            }
        } ?? []
        return LensCorrection(
            source: .dng,
            center: center,
            radii: radii,
            distortion: distortion.allSatisfy { ($0 * 0).sum() == 0 } ? distortion : [],
            vignetting: vignetting.allSatisfy(\.isFinite) ? vignetting : [],
        )
    }

    /// Fujifilm's correction tags: knots at radii of the half-diagonal (scaled by 1.25 in the
    /// cameras' 1.25× crop modes, which aren't read yet). Distortion is in percent of the radius,
    /// red's and blue's scale a fraction on top, and vignetting the brightness left in percent,
    /// whose gain is its inverse squared: the conventions darktable uses.
    static func fujifilm(
        knots: [Double], distortion: [Double], red: [Double], blue: [Double], vignetting: [Double],
    ) -> LensCorrection? {
        let count = knots.count
        guard count >= 2, distortion.count == count, red.count == count, blue.count == count,
              vignetting.count == count, zip(knots, knots.dropFirst()).allSatisfy({ $0 < $1 }),
              vignetting.allSatisfy({ $0 > 1 })
        else { return nil }
        let scales = (0 ..< count).map { i -> SIMD3<Double> in
            let green = 1 + distortion[i] / 100
            return SIMD3(green * (1 + red[i]), green, green * (1 + blue[i]))
        }
        let gains = vignetting.map { 1 / pow($0 / 100, 2) }
        return LensCorrection(
            source: .fujifilm, center: SIMD2(0.5, 0.5), radii: knots, distortion: scales, vignetting: gains,
        )
    }

    /// Sony's correction tags: up to 16 knots at radii (i + ½) / (n − 1) of the half-diagonal.
    /// Distortion is 1 + d·2⁻¹⁴, red and blue further 1 + c·2⁻²¹, and the vignetting gain the
    /// inverse of (2^(½ − 2^(v·2⁻¹³ − 1)))², the conventions darktable and RawTherapee use.
    static func sony(distortion: [Int], chromaticAberration: [Int], vignetting: [Int]) -> LensCorrection? {
        let count = [distortion.count, vignetting.count, chromaticAberration.count / 2].filter { $0 > 0 }.min() ?? 0
        guard count >= 2 else { return nil }
        let radii = (0 ..< count).map { (Double($0) + 0.5) / Double(count - 1) }
        let scales = distortion.isEmpty ? [] : (0 ..< count).map { i -> SIMD3<Double> in
            let green = 1 + Double(distortion[i]) * pow(2, -14)
            guard chromaticAberration.count >= 2 * count else { return SIMD3(repeating: green) }
            let red = green * (1 + Double(chromaticAberration[i]) * pow(2, -21))
            let blue = green * (1 + Double(chromaticAberration[count + i]) * pow(2, -21))
            return SIMD3(red, green, blue)
        }
        let gains = vignetting.isEmpty ? [] : (0 ..< count).map { i -> Double in
            let shading = pow(2, 0.5 - pow(2, Double(vignetting[i]) * pow(2, -13) - 1))
            return 1 / max(shading * shading, 1e-4)
        }
        return LensCorrection(
            source: .sony, center: SIMD2(0.5, 0.5), radii: radii, distortion: scales, vignetting: gains,
        )
    }

    /// Radii of the tables made from a maker's polynomial, in units of the farthest corner.
    private static let polynomialRadii = (0 ... 64).map { Double($0) / 64 * 1.05 }

    /// Panasonic's distortion tag (0x0119, 16 signed words): a recorded radius r is corrected to
    /// r(1 + (w₈r² + w₄r⁴ + w₁₁r⁶)·2⁻¹⁵) / (1 + w₅·2⁻¹⁵), in units of word 12 (the sensor's
    /// half-diagonal in photosites) about the active area's centre, which `unit` gives in units
    /// of the photo's farthest corner from `center`. Tabulated by inverting that, so it must keep
    /// increasing out to the corners.
    static func panasonic(words: [Int], center: SIMD2<Double>, unit: Double) -> LensCorrection? {
        guard words.count >= 13, unit > 0.5, unit < 2 else { return nil }
        let (a, b, c) = (Double(words[8]), Double(words[4]), Double(words[11]))
        let scale = 1 + Double(words[5]) / 32768
        guard scale > 0.8, scale < 1.25, a != 0 || b != 0 || c != 0 || scale != 1 else { return nil }
        func corrected(_ r: Double) -> Double {
            let r2 = r * r
            return r * (1 + (a * r2 + b * r2 * r2 + c * r2 * r2 * r2) / 32768) / scale
        }
        // Where the correction stops increasing, past which it has no inverse.
        var limit = 0.0
        while limit < 2, corrected(limit + 1e-3) > corrected(limit) {
            limit += 1e-3
        }
        guard corrected(limit) * unit >= 1 else { return nil }
        let scales = polynomialRadii.map { radius -> SIMD3<Double> in
            let target = min(radius / unit, corrected(limit))
            guard target > 0 else { return SIMD3(repeating: scale) }
            var (low, high) = (0.0, limit)
            for _ in 0 ..< 60 {
                let middle = (low + high) / 2
                if corrected(middle) < target {
                    low = middle
                } else {
                    high = middle
                }
            }
            return SIMD3(repeating: (low + high) / 2 / target)
        }
        return LensCorrection(
            source: .panasonic, center: center, radii: polynomialRadii, distortion: scales, vignetting: [],
        )
    }

    /// Olympus's and OM System's distortion tag (ImageProcessing 0x150A: k₁, k₂, k₃ and a scale
    /// s): a corrected radius r was recorded at x(1 + k₁x² + k₂x⁴ + k₃x⁶), x = s·r, in units of the
    /// camera crop's half-diagonal about its centre, which `unit` gives in units of the photo's
    /// farthest corner from `center`.
    static func omSystem(coefficients k: [Double], center: SIMD2<Double>, unit: Double) -> LensCorrection? {
        guard k.count >= 4, k.allSatisfy(\.isFinite), k[0 ... 2].allSatisfy({ abs($0) < 1 }), k[3] > 0.8, k[3] < 1.25,
              unit > 0.5, unit < 2, k[0 ... 2].contains(where: { $0 != 0 }) || k[3] != 1
        else { return nil }
        let scales = polynomialRadii.map { radius -> SIMD3<Double> in
            let x = k[3] * radius / unit, x2 = x * x
            return SIMD3(repeating: k[3] * (1 + k[0] * x2 + k[1] * x2 * x2 + k[2] * x2 * x2 * x2))
        }
        return LensCorrection(
            source: .omSystem, center: center, radii: polynomialRadii, distortion: scales, vignetting: [],
        )
    }
}
