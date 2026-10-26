import Foundation
import LibRaw

/// A raw's crop factor, 35 mm film's diagonal over its frame's, which scales a lens profile made on
/// another body (LNS-14).
enum CropFactor {
    /// 35 mm film's diagonal, in millimetres.
    static let fullFrameDiagonal = (36.0 * 36.0 + 24.0 * 24.0).squareRoot()

    /// The crop factor of a raw LibRaw has opened. The 35 mm-equivalent focal length the file
    /// states follows a crop mode, but is rounded to a millimetre, so the factor of the format
    /// LibRaw knows the camera by stands in where the stated length rounds to it. Without that
    /// length (Canon's files), the format LibRaw knows, unless the focal plane resolution EXIF
    /// states makes the frame full frame: LibRaw takes a Canon body it doesn't know for APS-C.
    static func of(_ raw: UnsafeMutablePointer<libraw_data_t>, focalPlane: () -> Double?) -> Double? {
        let lens = raw.pointee.lens
        let format = nominal(format: Int(lens.makernotes.CameraFormat), make: RawDecoder.string(rl_make(raw)))
        let focal = Double(raw.pointee.other.focal_len)
        let equivalent = lens.FocalLengthIn35mmFormat > 0
            ? Double(lens.FocalLengthIn35mmFormat) : Double(lens.makernotes.FocalLengthIn35mmFormat)
        return of(focalLength: focal, equivalent: equivalent, format: format, focalPlane: focalPlane)
    }

    static func of(
        focalLength focal: Double, equivalent: Double, format: Double?, focalPlane: () -> Double?,
    ) -> Double? {
        if focal > 0, equivalent > 0 {
            let stated = equivalent / focal
            guard stated > 0.2, stated < 20 else { return format }
            if let format, abs(equivalent - focal * format) <= 0.5 + 0.02 * equivalent {
                return format
            }
            return stated
        }
        if let plane = focalPlane(), abs(plane - 1) < 0.05 {
            return 1
        }
        return format
    }

    /// The crop factor of a sensor format LibRaw names (`LibRaw_camera_formats`), from its usual
    /// size: Canon's APS-C is 22.3 mm wide, others' 23.5 mm. Nil for formats of no one size.
    static func nominal(format: Int, make: String?) -> Double? {
        let canon = make?.lowercased().hasPrefix("canon") == true
        return switch format {
        case 1: canon ? 1.61 : 1.53 // APS-C
        case 2: 1 // full frame
        case 4: 1.29 // APS-H
        case 5: 2.73 // 1-inch
        case 6: 5.64 // 1/2.3-inch
        case 7: 4.55 // 1/1.7-inch
        case 8: 2 // Four Thirds and Micro Four Thirds
        case 9: 0.79 // 44 × 33 mm
        case 10: 0.8 // Leica S
        case 11: 0.65 // 645, 53.4 × 40 mm
        case 17: 1.74 // Sigma's first APS-C, 20.7 × 13.8 mm
        case 18: 1.5 // Sigma Merrill, 24 × 16 mm
        case 19: 1.35 // Sigma sd Quattro H, 26.7 × 17.9 mm
        default: nil
        }
    }

    /// The crop factor the EXIF focal plane resolution and the image's EXIF size give (Canon writes
    /// both, LibRaw reads neither): from the TIFF's Exif IFD, or a CR3's CMT2 box, which holds it.
    static func focalPlane(_ data: Data, url: URL) -> Double? {
        data.withUnsafeBytes { bytes -> Double? in
            if url.pathExtension.lowercased() == "cr3" {
                let head = UnsafeRawBufferPointer(rebasing: bytes.prefix(1 << 20))
                guard let box = head.firstRange(of: Array("CMT2".utf8)),
                      let reader = TIFFReader(bytes: UnsafeRawBufferPointer(rebasing: bytes[box.upperBound...]))
                else { return nil }
                return focalPlane(reader.entries(at: Int(reader.u32(4))), reader: reader)
            }
            guard let reader = TIFFReader(bytes: bytes),
                  let exif = reader.imageFileDirectories().first?.first(where: { $0.tag == 0x8769 })
            else { return nil }
            return focalPlane(reader.entries(at: Int(reader.u32(exif.valueOffset))), reader: reader)
        }
    }

    /// FocalPlaneXResolution and YResolution (pixels per inch, centimetre or millimetre) over
    /// PixelXDimension and YDimension.
    private static func focalPlane(_ entries: [TIFFReader.Entry]?, reader: TIFFReader) -> Double? {
        guard let entries else { return nil }
        func value(_ tag: UInt16) -> Double? {
            guard let entry = entries.first(where: { $0.tag == tag }) else { return nil }
            let value = entry.type == 5 ? DNGColorCalibration.rationals(entry, reader: reader).first
                : reader.integers(entry).first.map(Double.init)
            return value.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        }
        let millimetres: Double? = switch value(0xA210).map(Int.init) {
        case 2: 25.4
        case 3: 10
        case 4: 1
        default: nil
        }
        guard let millimetres, let xResolution = value(0xA20E), let yResolution = value(0xA20F),
              let width = value(0xA002), let height = value(0xA003)
        else { return nil }
        let diagonal = hypot(width / xResolution, height / yResolution) * millimetres
        return diagonal > 3 && diagonal < 100 ? fullFrameDiagonal / diagonal : nil
    }
}
