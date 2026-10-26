import Foundation
import AppKit
import CoreImage

@main struct HDRIntegration {
    @MainActor static func main() async throws {
        for name in ["B0001851.HEIC", "B0001166.HEIC", "DSC00001.JPG"] {
            let url = URL(fileURLWithPath: "test_photo/" + name)
            let result = await MediaLoader.shared.photo(url: url, raw: false, full: false, hdr: true, maxDimension: 2400)
            guard result.error == nil, let image = result.image,
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("Loader failed: \(name)") }
            let ci = CIImage(cgImage: cg)
            let small = ci.transformed(by: CGAffineTransform(scaleX: 128 / ci.extent.width, y: 128 / ci.extent.height))
            var values = [Float](repeating: 0, count: 128 * 128 * 4)
            values.withUnsafeMutableBytes {
                CIContext(options: [.cacheIntermediates: false]).render(small, toBitmap: $0.baseAddress!, rowBytes: 128 * 16,
                    bounds: CGRect(x: 0, y: 0, width: 128, height: 128), format: .RGBAf,
                    colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
            }
            var peak: Float = 0
            for i in stride(from: 0, to: values.count, by: 4) { peak = max(peak, max(values[i], max(values[i + 1], values[i + 2]))) }
            if name.hasSuffix("HEIC") {
                precondition(cg.height == 2400 && cg.width == 1800 && cg.contentHeadroom > 1 && peak > 1)
            } else { precondition(peak > 0) }
            print(name, "MediaLoader → NSImage passed", cg.width, cg.height, "headroom", cg.contentHeadroom, "RGB peak", peak)
        }
    }
}
