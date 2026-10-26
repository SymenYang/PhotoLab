import Foundation
import ImageIO
import CoreImage
import CryptoKit

@main struct HEICHDRTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func pixels(_ image: CGImage) -> [Float] {
        let ci = CIImage(cgImage: image)
        let small = ci.transformed(by: CGAffineTransform(scaleX: 512 / ci.extent.width, y: 512 / ci.extent.height))
        var result = [Float](repeating: 0, count: 512 * 512 * 4)
        result.withUnsafeMutableBytes {
            CIContext(options: [.cacheIntermediates: false]).render(small, toBitmap: $0.baseAddress!, rowBytes: 512 * 16,
                bounds: CGRect(x: 0, y: 0, width: 512, height: 512), format: .RGBAf,
                colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        }
        return result
    }
    static func decode(_ source: CGImageSource, hdr: Bool, size: Int = 2560) -> CGImage {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceDecodeRequest: hdr ? kCGImageSourceDecodeToHDR : kCGImageSourceDecodeToSDR
        ] as CFDictionary)!
    }
    static func main() throws {
        guard let references = ProcessInfo.processInfo.environment["PHOTOLAB_HEIC_REFERENCES"] else {
            fatalError("Set PHOTOLAB_HEIC_REFERENCES to the validated reference fixture directory")
        }
        for name in ["B0001851", "B0001166"] {
            try autoreleasepool {
                let url = URL(fileURLWithPath: "test_photo/\(name).HEIC")
                let original = try Data(contentsOf: url)
                let hash = SHA256.hash(data: original)
                let start = Date()
                guard let patched = HEICHDRCompatibility.normalizedData(original) else { fatalError("No match: \(name)") }
                print(name, "normalize seconds", Date().timeIntervalSince(start))
                let reference = try Data(contentsOf: URL(fileURLWithPath: "\(references)/\(name)-HDR-compatible.HEIC"))
                check(patched == reference, "Memory output must exactly match validated offline reference")
                check(HEICHDRCompatibility.normalizedData(patched) == nil, "Already-normalized file must be untouched")
                check(original.count == patched.count && original.suffix(from: 3056) == patched.suffix(from: 3056), "Encoded media changed")
                let source = HEICHDRCompatibility.source(url: url, hdr: true)!
                let image = decode(source, hdr: true)
                check(image.width < image.height && image.height == 2560, "Incorrect orientation/size")
                let hdr = pixels(image)
                var peak: Float = 0
                for i in stride(from: 0, to: hdr.count, by: 4) {
                    peak = max(peak, 0.2126 * hdr[i] + 0.7152 * hdr[i + 1] + 0.0722 * hdr[i + 2])
                }
                print(name, "measured HDR peak", peak, "headroom", image.contentHeadroom); fflush(stdout)
                check(peak > 1.5 && peak < 9 && hdr.allSatisfy(\.isFinite), "Invalid/black HDR output")
                check(image.contentHeadroom > 1, "HDR headroom missing")
                let nativeSDR = decode(HEICHDRCompatibility.source(url: url, hdr: false)!, hdr: false)
                let normalizedSDR = decode(source, hdr: false)
                let diff = zip(pixels(nativeSDR), pixels(normalizedSDR)).map { abs($0 - $1) }.max()!
                check(diff == 0, "SDR changed")
                let after = try Data(contentsOf: url)
                check(SHA256.hash(data: after) == hash, "Source was modified")
                print(name, "HDR", image.width, image.height, "headroom", image.contentHeadroom, "peak Y", peak, "SDR difference", diff)
                if CommandLine.arguments.contains("--full") {
                    let full = decode(source, hdr: true, size: 11656)
                    check(full.width == 8742 && full.height == 11656 && full.contentHeadroom > 1, "Full-resolution HDR failed")
                    check(pixels(full).max()! > 1, "Full-resolution HDR black")
                    print(name, "full resolution passed")
                }
                if name == "B0001851" {
                    for length in 0..<3100 {
                        check(HEICHDRCompatibility.normalizedData(Data(original.prefix(length))) == nil, "Truncation accepted")
                    }
                    // Corrupt box lengths and headers: parser must reject or safely leave native handling.
                    for offset in stride(from: 0, to: 2672, by: 7) {
                        var bad = original
                        bad.replaceSubrange(offset..<offset + 4, with: [255, 255, 255, 255])
                        _ = HEICHDRCompatibility.normalizedData(bad)
                    }
                }
            }
        }
        check(HEICHDRCompatibility.normalizedData(Data("not a HEIF".utf8)) == nil, "Non-HEIF accepted")
        print("HEIC HDR compatibility tests passed")
    }
}
