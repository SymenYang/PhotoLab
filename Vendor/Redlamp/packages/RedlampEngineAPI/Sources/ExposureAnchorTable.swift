import Foundation

/// Each camera's exposure anchor as Redlamp measures it (CAM-29): how many stops a camera's photos
/// need beyond the typical camera's to open as bright as its own JPEGs, from the camera bench's
/// comparisons over raw.pixls.us's CC0 files (`Resources/ExposureAnchors.json`, which
/// `scripts/exposure-anchors.py` makes). A camera the table lacks gets its maker and format's
/// median, else its maker's, else the typical anchor. A user's calibration from a target always
/// wins over it.
public struct ExposureAnchorTable: Codable, Sendable {
    /// Stops beyond `ExposureAnchor.typicalStops`, by `ImageInfo.cameraName`.
    public var cameras: [String: Double]
    /// By make and format family, `Canon|CR3`.
    public var families: [String: Double]
    /// By make, as the files state it.
    public var makes: [String: Double]

    public init(cameras: [String: Double] = [:], families: [String: Double] = [:], makes: [String: Double] = [:]) {
        self.cameras = cameras
        self.families = families
        self.makes = makes
    }

    public static let bundled: ExposureAnchorTable = {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: "ExposureAnchors", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode(ExposureAnchorTable.self, from: data)
        else { return ExposureAnchorTable() }
        return table
    }()

    /// The estimate for a photo from `make`'s `model` in a file with the extension `format`.
    public func anchor(make: String?, model: String?, format: String) -> ExposureAnchor {
        let camera = ImageInfo.cameraName(make: make, model: model)
        let family = Self.family(of: format)
        let stops = camera.flatMap { cameras[$0] }
            ?? make.flatMap { families["\($0)|\(family)"] ?? makes[$0] }
            ?? 0
        return ExposureAnchor(stops: ExposureAnchor.typicalStops + stops, source: .estimated, camera: camera)
    }

    /// The estimate for the photo `info` describes; nil when it isn't raw.
    public func anchor(for info: ImageInfo) -> ExposureAnchor? {
        info.isRaw ? anchor(make: info.make, model: info.model, format: info.url.pathExtension) : nil
    }

    /// Formats whose cameras' JPEGs the bench finds alike share a family: a maker's older and
    /// newer extensions for the same kind of body.
    static func family(of format: String) -> String {
        let format = format.uppercased()
        return ["CRW": "CR2", "NRW": "NEF", "SRF": "ARW", "SR2": "ARW", "RWL": "RW2"][format] ?? format
    }
}

private final class BundleToken {}
