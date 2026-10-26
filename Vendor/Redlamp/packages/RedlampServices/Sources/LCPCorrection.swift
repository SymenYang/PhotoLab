import Foundation
import RedlampEngineAPI
import simd

/// The Adobe Camera Model's rectilinear and fisheye equations, tabulated into a `LensCorrection` as
/// `LensCorrection.tabulated` tabulates DNG opcodes. A point (x, y) from the principal point,
/// over the focal length, both in pixels, is recorded at (x, y)·s·(1 + k₁r² + k₂r⁴ + k₃r⁶), r² =
/// x² + y², plus tangential terms in k₄ and k₅; through a fisheye, at (x, y)·(θ/r)(1 + k₁θ² +
/// k₂θ⁴), θ = atan r, which turns the photo rectilinear. Red is recorded at green's recorded point
/// (x_d, y_d) times α₀(1 + α₁r_d² + α₂r_d⁴ + α₃r_d⁶), r_d² = x_d² + y_d², and blue likewise with β.
/// A recorded point keeps 1 + α₁r_d² + α₂r_d⁴ + α₃r_d⁶ of its light, which the vignetting gain
/// undoes.
extension LCPProfile {
    /// `LensCorrection.tabulated`'s radii: 1 is the corner farthest from the centre.
    static let radii = (0 ... 32).map { Double($0) / 32 * 1.05 }

    /// How a profile's models reach a photo: as recorded, on the body it was made on and a frame of
    /// the reference photos' shape and size; or scaled to another frame (another body, or a crop
    /// mode, LNS-14), `ratio` being the reference photos' larger side over the photo's, in millimetres.
    enum Fit: Equatable {
        case recorded
        case scaled(Double)

        var ratio: Double {
            switch self {
            case .recorded: 1
            case let .scaled(ratio): ratio
            }
        }
    }

    /// The correction one camera and lens's sub-profiles give a photo of `size` pixels as the
    /// sensor recorded it (before `orientation`, as the reference photos were), shot at
    /// `focalLength` millimetres and f/`aperture`. Every model is taken about the geometric
    /// model's centre (the colour and vignette models' are within a pixel or so of it), and the
    /// tangential terms are left out, as they are for DNG opcodes. The correction is named for the
    /// lens as the profile's author names it.
    static func correction(
        _ subProfiles: [SubProfile], focalLength: Double?, aperture: Double?, size: PixelSize, orientation: Int,
        fit: Fit = .recorded,
    ) -> LensCorrection? {
        let size = SIMD2(Double(size.width), Double(size.height))
        guard size.min() > 0 else { return nil }
        let fitting = fit == .recorded ? subProfiles.filter { $0.fits(size) } : subProfiles
        let geometric = weights(fitting.filter { $0.geometry != nil }, focalLength: focalLength, aperture: aperture)
        let vignetted = weights(fitting.filter { $0.vignette != nil }, focalLength: focalLength, aperture: aperture)
        let principalPoints = geometric.isEmpty
            ? vignetted.compactMap { item in
                item.subProfile.vignette.map { (item.subProfile.center($0, in: size, fit: fit), item.weight) }
            }
            : geometric.compactMap { item in
                item.subProfile.geometry.map { (item.subProfile.center($0, in: size, fit: fit), item.weight) }
            }
        guard !principalPoints.isEmpty else { return nil }
        let center = principalPoints.reduce(SIMD2<Double>.zero) { sum, point in sum + point.0 * point.1 }
        let reach = simd_length(simd_max(center, size - center))

        // A model that can't be evaluated makes its table NaN, which the checks below drop.
        var distortion = [SIMD3<Double>](repeating: .zero, count: geometric.isEmpty ? 0 : radii.count)
        var vignetting = [Double](repeating: 0, count: vignetted.isEmpty ? 0 : radii.count)
        for (index, radius) in radii.enumerated() {
            for (subProfile, weight) in geometric {
                let scales = subProfile.scales(at: radius * reach, size: size, fit: fit)
                distortion[index] += (scales ?? SIMD3(repeating: .nan)) * weight
            }
            for (subProfile, weight) in vignetted {
                vignetting[index] += (subProfile.gain(at: radius * reach, size: size, fit: fit) ?? .nan) * weight
            }
        }
        if !rises(distortion) {
            distortion = []
        }
        if !vignetting.allSatisfy({ $0.isFinite && $0 > 0 }) {
            vignetting = []
        }
        guard !distortion.isEmpty || !vignetting.isEmpty else { return nil }
        return LensCorrection(
            source: .profile,
            center: LensCorrectionReader.oriented(center / size, orientation),
            radii: radii,
            distortion: distortion,
            vignetting: vignetting,
            profileName: subProfiles.lazy.compactMap { $0.lensPrettyName ?? $0.lens ?? $0.profileName }.first,
        )
    }

    /// Each sub-profile's weight at `focalLength` and f/`aperture`: linear in focal length between
    /// the calibrated focal lengths around it, and at each of those linear in aperture, in stops
    /// as APEX values are, between the calibrated apertures around it, holding the ends. Without
    /// the photo's aperture, the narrowest calibrated one, which corrects least; without its focal
    /// length, only a profile made at one focal length applies. Of sub-profiles made at one
    /// setting, the one focused farthest, since raw files rarely say how far they were focused.
    static func weights(
        _ subProfiles: [SubProfile], focalLength: Double?, aperture: Double?,
    ) -> [(subProfile: SubProfile, weight: Double)] {
        let byFocalLength = Dictionary(grouping: subProfiles) { ($0.focalLength * 100).rounded() / 100 }
        let focalLengths = byFocalLength.keys.sorted()
        let shot = focalLength.flatMap { $0 > 0 ? $0 : nil } ?? (focalLengths.count == 1 ? focalLengths.first : nil)
        guard let shot else { return [] }
        let apex = aperture.flatMap { $0 > 0 ? 2 * log2($0) : nil }
        return bracket(focalLengths, shot).flatMap { focal, focalWeight in
            let byAperture = Dictionary(grouping: byFocalLength[focal] ?? []) {
                ($0.apertureValue * 1000).rounded() / 1000
            }
            .compactMapValues { group in group.max { ($0.focusDistance ?? 0) < ($1.focusDistance ?? 0) } }
            let apertures = byAperture.keys.sorted()
            return bracket(apertures, apex ?? apertures.last ?? 0).compactMap { value, weight in
                byAperture[value].map { (subProfile: $0, weight: focalWeight * weight) }
            }
        }
    }

    /// The values around `x` among `values` (ascending) with their weights; the nearest end alone
    /// outside them.
    static func bracket(_ values: [Double], _ x: Double) -> [(value: Double, weight: Double)] {
        guard let first = values.first, let last = values.last else { return [] }
        guard x > first else { return [(first, 1)] }
        guard x < last, let upper = values.firstIndex(where: { $0 >= x }) else { return [(last, 1)] }
        let (low, high) = (values[upper - 1], values[upper])
        let t = (x - low) / (high - low)
        return [(low, 1 - t), (high, t)].filter { $0.weight > 0 }
    }

    /// Whether every channel's scale is positive and its recorded radius rises with the radius,
    /// as the geometry's inverse needs.
    private static func rises(_ table: [SIMD3<Double>]) -> Bool {
        let recorded = zip(radii, table).map { radius, scale in scale * radius }
        let increasing = zip(recorded, recorded.dropFirst()).allSatisfy { ($1 - $0).min() > 0 }
        return increasing && table.allSatisfy { $0.min() > 0 }
    }
}

extension LCPProfile.SubProfile {
    /// The model green's geometry follows: the colour model's own, else the geometric model. Both
    /// take the fisheye form in a fisheye profile.
    var geometry: LCPProfile.Model? {
        chromatic?.green ?? distortion
    }

    /// Whether the photo has the reference photos' shape and size, within what LibRaw's and
    /// Adobe's frames differ by. The model is a fraction of the larger side, so a crop mode's
    /// frame would move it (another shape) or scale it (APS-C on a full-frame body), and a raw
    /// doesn't say whether a smaller frame is cropped or downsampled.
    func fits(_ size: SIMD2<Double>) -> Bool {
        guard let imageSize, imageSize.min() > 0 else { return true }
        let shape = size.max() / size.min() / (imageSize.max() / imageSize.min())
        return abs(shape - 1) < 0.03 && abs(size.max() / imageSize.max() - 1) < 0.05
    }

    /// The reference photos' larger side over a photo's, in millimetres, for a photo of `size`
    /// (sensor-oriented) and `cropFactor`, from each one's crop factor and shape (the photo's, where
    /// the profile doesn't give its photos' size). Formats within 4% of each other are taken for
    /// one: their crop factors are rounded, and a camera's frame differs from its format's by as much.
    func ratio(toCropFactor cropFactor: Double, size: SIMD2<Double>) -> Double? {
        guard let factor = sensorFormatFactor, factor > 0, cropFactor > 0, size.min() > 0 else { return nil }
        let shape = size.max() / simd_length(size)
        let referenceShape = imageSize.flatMap { $0.min() > 0 ? $0.max() / simd_length($0) : nil } ?? shape
        return (abs(cropFactor / factor - 1) < 0.04 ? 1 : cropFactor / factor) * referenceShape / shape
    }

    /// A model's focal length in pixels for a photo of `size`: fx and fy (their geometric mean)
    /// times the larger side or, where the file leaves them out, the focal length in millimetres
    /// times pixels per millimetre, the sensor's diagonal being 35 mm film's over the format factor.
    /// Scaled, the reference photos' larger side maps onto the photo's times the fit's ratio.
    func pixelFocalLength(_ model: LCPProfile.Model, size: SIMD2<Double>, fit: LCPProfile.Fit = .recorded) -> Double? {
        if let f = model.focalLength {
            return f.min() > 0 ? (f.x * f.y).squareRoot() * size.max() * fit.ratio : nil
        }
        guard let factor = sensorFormatFactor, factor > 0 else { return nil }
        guard case let .scaled(ratio) = fit else {
            return focalLength * factor * simd_length(size) / simd_length(SIMD2<Double>(36, 24))
        }
        let shape = imageSize.flatMap { $0.min() > 0 ? $0.max() / simd_length($0) : nil }
            ?? size.max() / simd_length(size)
        return focalLength * size.max() * ratio / (CropFactor.fullFrameDiagonal / factor * shape)
    }

    /// A model's principal point in pixels for a photo of `size`: as recorded, or scaled, the
    /// photo's centre moved by the model's offset from the reference photos' centre.
    func center(_ model: LCPProfile.Model, in size: SIMD2<Double>, fit: LCPProfile.Fit) -> SIMD2<Double> {
        guard case let .scaled(ratio) = fit else { return model.center(in: size) }
        guard let reference = imageSize, reference.min() > 0 else { return size / 2 }
        let middle = reference / 2 / reference.max()
        let offset = SIMD2(model.centerX ?? middle.x, model.centerY ?? middle.y) - middle
        return size / 2 + offset * size.max() * ratio
    }

    /// Where red, green and blue are recorded, as multiples of `radius`, a distance in pixels from
    /// the centre of the corrected photo.
    func scales(at radius: Double, size: SIMD2<Double>, fit: LCPProfile.Fit = .recorded) -> SIMD3<Double>? {
        guard let geometry, let f = pixelFocalLength(geometry, size: size, fit: fit) else { return nil }
        let green = geometry.scale * (isFisheye ? geometry.fisheye(radius / f) : geometry.polynomial(radius / f))
        guard let chromatic else { return SIMD3(repeating: green) }
        guard let red = pixelFocalLength(chromatic.red, size: size, fit: fit),
              let blue = pixelFocalLength(chromatic.blue, size: size, fit: fit)
        else { return nil }
        let recorded = green * radius
        return SIMD3(
            green * chromatic.red.scale * chromatic.red.polynomial(recorded / red),
            green,
            green * chromatic.blue.scale * chromatic.blue.polynomial(recorded / blue),
        )
    }

    /// The gain that undoes the vignette at `radius`, a distance in pixels from the centre of the
    /// recorded photo; nil where the model leaves no light.
    func gain(at radius: Double, size: SIMD2<Double>, fit: LCPProfile.Fit = .recorded) -> Double? {
        guard let vignette, let f = pixelFocalLength(vignette, size: size, fit: fit) else { return nil }
        let kept = vignette.polynomial(radius / f)
        return kept > 0 ? 1 / kept : nil
    }
}

extension LCPProfile.Model {
    /// The principal point in pixels for a photo of `size`: u₀ and v₀ times its larger side, or its
    /// centre where the file leaves them out.
    func center(in size: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2(centerX.map { $0 * size.max() } ?? size.x / 2, centerY.map { $0 * size.max() } ?? size.y / 2)
    }

    /// 1 + c₁r² + c₂r⁴ + c₃r⁶, the coefficients `radial`.
    func polynomial(_ r: Double) -> Double {
        let r2 = r * r
        return 1 + r2 * (radial.x + r2 * (radial.y + r2 * radial.z))
    }

    /// (θ/r)(1 + k₁θ² + k₂θ⁴ + k₃θ⁶), θ = atan r: where the fisheye model records a point r from the
    /// principal point, over the focal length, as a multiple of r.
    func fisheye(_ r: Double) -> Double {
        let theta = atan(r)
        return (r > 0 ? theta / r : 1) * polynomial(theta)
    }
}
