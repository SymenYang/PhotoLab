import Foundation
import RedlampEngineAPI
import RedlampServices
import Synchronization

/// The user's lens profiles as an open raw's edits can name them (LNS-15): each named profile's
/// correction for the photo, found once and kept with the photo.
final class LensProfileResolver: Sendable {
    let library: LCPProfileLibrary
    let info: ImageInfo
    /// The photo as the sensor recorded it, before its orientation, as lens profiles describe it.
    let sensorSize: PixelSize
    let orientation: Int
    private let resolved = Mutex<[LensProfileChoice: LensCorrection?]>([:])

    init(library: LCPProfileLibrary, info: ImageInfo, sensorSize: PixelSize, orientation: Int) {
        self.library = library
        self.info = info
        self.sensorSize = sensorSize
        self.orientation = orientation
    }

    /// The named profile's correction; nil where it isn't on this Mac or can't fit the photo.
    func correction(for choice: LensProfileChoice) -> LensCorrection? {
        if let known = resolved.withLock({ $0[choice] }) {
            return known
        }
        let correction = library.correction(
            named: choice, for: info, sensorSize: sensorSize, orientation: orientation,
        )
        resolved.withLock { $0[choice] = .some(correction) }
        return correction
    }

    func options() -> [LensProfileOption] {
        library.options(for: info)
    }
}
