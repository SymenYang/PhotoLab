import Foundation

/// Where Redlamp Reproduction puts a camera's metered grey (CAM-28): the stops added to Exposure,
/// in place of a DNG's BaselineExposure, that put an 18% grey the meter read at scene 0.18 in the
/// white-balanced raw, whose clip is 1. Each edit that uses the look keeps its own photo's camera's
/// (`docs/plans/2026-10-09-reproduction-design.md`).
public struct ExposureAnchor: Codable, Sendable, Hashable {
    /// Where the stops came from. A value a newer Redlamp wrote is kept as it is.
    public struct Source: RawRepresentable, Codable, Sendable, Hashable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// Measured from a target with Calibrate from Target.
        public static let target = Source(rawValue: "target")
        /// The camera has no calibration: `typicalStops`.
        public static let typical = Source(rawValue: "typical")
        /// From the table Redlamp measures from cameras' own JPEGs (`ExposureAnchorTable`, CAM-29);
        /// a DNG's BaselineExposure is added to it when it renders.
        public static let estimated = Source(rawValue: "estimated")
    }

    /// A metered grey 3.5 stops below clip, the middle of the 3.3 to 3.7 stops cameras' ISO
    /// calibrations put it at; on those cameras it lands between L* 46.5 and 52.6.
    public static let typicalStops = 1.03

    /// From process 16, the stops every look but Redlamp Reproduction adds beyond the anchor's
    /// distance from the typical one, so that a typical camera's metered grey opens as bright as
    /// cameras' own JPEGs render it (CAM-29): the camera bench's median offset at process 15, 0.36
    /// stops in its midtones, which the curve's contrast moves 1.37 times as far as the exposure.
    /// Process 16's, fixed with it.
    public static let lookStops = 0.26

    /// The stops it puts a metered grey at for a file whose BaselineExposure is `baseline`: an
    /// estimate was measured with the files' BaselineExposure applied, so it carries this one's.
    public func stops(baseline: Double) -> Double {
        source == .estimated ? stops + baseline : stops
    }

    public var stops: Double
    public var source: Source
    /// The camera it belongs to, as `ImageInfo.cameraName` names it.
    public var camera: String?
    /// Fields written by a newer Redlamp, written back unchanged.
    public var unknownFields: [String: JSONValue] = [:]

    public init(stops: Double, source: Source, camera: String?) {
        self.stops = stops
        self.source = source
        self.camera = camera
    }

    /// The typical anchor, for a camera without a calibration.
    public static func typical(for camera: String?) -> ExposureAnchor {
        ExposureAnchor(stops: typicalStops, source: .typical, camera: camera)
    }
}

public extension EditRecipe {
    /// This edit with its photo's anchor, `photo` (the camera's calibration, else its estimate from
    /// process 16 and the typical anchor before; nil for a photo that isn't raw): `photo` unless
    /// the edit already has one for that camera, under Redlamp Reproduction and, from process 16,
    /// under every look (CAM-29); under any other look at an older process, none.
    func anchored(_ photo: ExposureAnchor?) -> EditRecipe {
        var result = self
        guard baseLook.isReproduction || processVersion >= 16, let photo else {
            result.exposureAnchor = nil
            return result
        }
        if exposureAnchor == nil || exposureAnchor?.camera != photo.camera {
            result.exposureAnchor = photo
        }
        return result
    }
}
