import Foundation
import AppKit
import CoreImage
import ImageIO
import CryptoKit
import UniformTypeIdentifiers

func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw CatalogError(message: message) }
}
func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func floatPixels(_ image: CIImage) -> [Float] {
    let scaled = image.transformed(by: CGAffineTransform(scaleX: min(1, 128/image.extent.width), y: min(1, 128/image.extent.width)))
    let bounds = CGRect(x: 0, y: 0, width: max(1, floor(scaled.extent.width)), height: max(1, floor(scaled.extent.height)))
    var values = [Float](repeating: 0, count: Int(bounds.width*bounds.height)*4)
    PhotoEditStore.context.render(scaled, toBitmap: &values, rowBytes: Int(bounds.width)*16, bounds: bounds, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
    return values
}
func difference(_ a: [Float], _ b: [Float]) -> Float { zip(a,b).map { abs($0-$1) }.max() ?? 0 }
@main struct EditTests {
    static func main() {
        do { try run(); print("PASS photo editing storage/render tests"); fflush(stdout) }
        catch { print("FAIL: \(error)"); fflush(stdout); exit(1) }
    }
    static func run() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("photolab-edits-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var pixels = [UInt8](repeating: 0, count: 256*128*4)
        for y in 0..<128 { for x in 0..<256 { let i = (y*256+x)*4; pixels[i] = UInt8(x); pixels[i+1] = UInt8(y); pixels[i+2] = 50; pixels[i+3] = 255 } }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cg = CGImage(width: 256, height: 128, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 1024, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let levels: [Float] = [0.01, 0.05, 0.2, 0.5, 1, 2, 4, 8]
        let floats = levels.flatMap { [$0, $0, $0, 1] as [Float] }
        let ramp = CIImage(bitmapData: floats.withUnsafeBytes { Data($0) }, bytesPerRow: levels.count*16, size: CGSize(width: levels.count,height: 1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        let linear = RAWLinearToneFilter(); linear.inputImage = ramp
        try require(difference(floatPixels(ramp),floatPixels(linear.outputImage!)) < 0.0001, "neutral linear stage altered data")
        linear.highlightCompression = 1
        let compressed = floatPixels(linear.outputImage!)
        for i in 1..<levels.count { try require(compressed[i*4] > compressed[(i-1)*4], "bright levels collapsed before SDR mapping") }
        try require(compressed[7*4] < 1 && compressed[7*4] > compressed[6*4], "HDR highlight compression failed")
        linear.highlightCompression = 0; linear.shadowLift = 1
        try require(floatPixels(linear.outputImage!)[4] > levels[1], "linear shadow adjustment did not lift dark detail")
        print("PASS floating-point ramp preserves distinct 1×, 2×, 4×, 8× highlights and lifts shadows")
        let source = temp.appendingPathComponent("original.jpg")
        try PhotoEditStore.encode(cg, to: source, tiff: false)
        let resetSource = temp.appendingPathComponent("reset.jpg")
        try FileManager.default.copyItem(at: source, to: resetSource)
        var neutral = PhotoAdjustments(); neutral.temperature = 12000; neutral.tint = 17
        try require(!neutral.hasEffectiveChanges, "As-shot hidden WB incorrectly marks an edit")
        neutral.asShot = false
        try require(neutral.hasEffectiveChanges, "Manual WB lost")
        var resetDoc = PhotoEditDocument(source: try EditSource.read(resetSource))
        resetDoc.adjustments.temperature = 12000
        let identity = try PhotoEditStore.save(resetDoc, source: resetSource, expectedToken: nil, cache: false)
        try require(PhotoEditStore.preferredSource([resetSource]) == nil, "Neutral sidecar overrides camera image")
        _ = try PhotoEditStore.commit(resetDoc, source: resetSource, expectedToken: identity.token, cache: true)
        try require(try PhotoEditStore.read(resetSource) == nil, "Reset kept identity cache")
        var alternate = PhotoEditVersion(); alternate.adjustments.exposure = 0.5
        resetDoc.versions.append(alternate)
        let retained = try PhotoEditStore.commit(resetDoc, source: resetSource, expectedToken: nil, cache: false)!
        try require(retained.document.versions.count == 2 && PhotoEditStore.preferredSource([resetSource]) == nil, "Inactive edit version deleted or active identity preferred")
        var newer = retained.document; newer.adjustments.saturation = 0.8
        let external = try PhotoEditStore.save(newer, source: resetSource, expectedToken: retained.token, cache: false)
        resetDoc.versions.removeLast()
        var refused = false
        do { _ = try PhotoEditStore.commit(resetDoc, source: resetSource, expectedToken: retained.token, cache: false) } catch { refused = true }
        try require(refused && (try PhotoEditStore.read(resetSource)?.token) == external.token, "Reset deleted concurrent changes")
        try require(PhotoEditStore.preferredSource([resetSource]) == resetSource, "Effective edit not preferred")
        print("PASS neutral edit filtering/deletion, as-shot WB, inactive version preservation and deletion conflicts")
        let originalHash = hash(try Data(contentsOf: source))
        try require(try PhotoEditStore.read(source) == nil, "unedited photo created sidecar")
        let originalImage = try PhotoEditStore.cgImage(PhotoEditStore.render(source, adjustments: PhotoAdjustments()))
        var document = PhotoEditDocument(source: try EditSource.read(source))
        document.adjustments.exposure = 0.8
        let editedImage = try PhotoEditStore.cgImage(PhotoEditStore.render(source, adjustments: document.adjustments))
        try require(originalImage.width == 256 && editedImage.width == 256 && editedImage.height == 128, "preview downscaled input")
        try require(hash(originalImage.dataProvider!.data! as Data) != hash(editedImage.dataProvider!.data! as Data), "exposure did not affect pixels")
        let draft = try PhotoEditStore.save(document, source: source, expectedToken: nil, cache: false)
        try require(draft.document.tiffBytes == 0 && draft.document.adjustments.exposure == 0.8, "draft roundtrip")
        let cached = try PhotoEditStore.save(draft.document, source: source, expectedToken: draft.token, cache: true)
        try require(cached.document.outputWidth == 256 && cached.document.outputHeight == 128 && cached.document.tiffBytes > 0, "full-size cache not generated")
        let full = try PhotoEditStore.preview(source, thumbnail: false)!
        let small = try PhotoEditStore.preview(source, thumbnail: true)!
        try require(full.size.width == 256 && small.size.width <= 480, "preview cache selection")
        let handle = try FileHandle(forReadingFrom: PhotoEditStore.sidecar(source))
        try handle.seek(toOffset: cached.payloadOffset)
        let bytes = try handle.read(upToCount: cached.document.tiffBytes)!
        try handle.close()
        let cacheCG = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(bytes as CFData, nil)!, 0, nil)!
        try require(cacheCG.bitsPerComponent == 16, "cache lost 16-bit precision")
        do { _ = try PhotoEditStore.save(document, source: source, expectedToken: draft.token, cache: false); throw CatalogError(message: "conflict overwrote newer file") }
        catch let error as CatalogError { try require(error.message.contains("其他程序"), error.message) }
        try require(try PhotoEditStore.read(source)!.token == cached.token, "conflict mutated existing sidecar")
        var crop = document; crop.adjustments.cropWidth = 0.5; crop.adjustments.cropHeight = 0.5
        let cropped = try PhotoEditStore.render(source, adjustments: crop.adjustments)
        try require(cropped.extent.width == 128 && cropped.extent.height == 64, "normalized crop dimensions")
        crop.adjustments.quarterTurns = 1
        let rotated = try PhotoEditStore.render(source, adjustments: crop.adjustments)
        try require(rotated.extent.width == 64 && rotated.extent.height == 128, "crop order after rotation")
        crop.adjustments.straighten = 8
        let straight = try PhotoEditStore.render(source, adjustments: crop.adjustments)
        try require(straight.extent.width > 0 && straight.extent.height > 0, "straighten failed")
        let savedCrop = try PhotoEditStore.save(crop, source: source, expectedToken: cached.token, cache: true)
        let exported = try PhotoEditStore.export(source, to: temp.appendingPathComponent("export.tiff"), options: PhotoExportOptions(format: .tiff))
        let exportCG = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(exported as CFURL, nil)!, 0, nil)!
        try require(exportCG.width == savedCrop.document.outputWidth && exportCG.bitsPerComponent == 16, "export differs from full render")
        let jpg = try PhotoEditStore.export(source, to: temp.appendingPathComponent("export.jpg"))
        let jpgSource = CGImageSourceCreateWithURL(jpg as CFURL, nil)!
        let jpgCG = CGImageSourceCreateImageAtIndex(jpgSource, 0, nil)!
        try require(CGImageSourceGetType(jpgSource) == UTType.jpeg.identifier as CFString, "default export is not JPEG")
        try require(jpgCG.width == exportCG.width && jpgCG.height == exportCG.height, "JPEG lost saved crop/rotation")
        try require(difference(floatPixels(CIImage(cgImage: jpgCG)), floatPixels(CIImage(cgImage: exportCG))) < 0.15, "JPEG differs from edited result")
        let lowQuality = try PhotoEditStore.export(source, to: temp.appendingPathComponent("low-quality.jpg"), options: PhotoExportOptions(quality: 0.1))
        try require(try Data(contentsOf: lowQuality).count < Data(contentsOf: jpg).count, "JPEG quality did not reduce file size")
        let hdrSource = temp.appendingPathComponent("hdr.heic")
        let hdrImage = CIImage(color: CIColor(red: 2.5, green: 1.5, blue: 0.5, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)!).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 64))
        try PhotoEditStore.context.writeHEIF10Representation(of: hdrImage, to: hdrSource, colorSpace: CGColorSpace(name: CGColorSpace.itur_2100_PQ)!, options: [:])
        let hdrJPG = try PhotoEditStore.export(hdrSource, to: temp.appendingPathComponent("hdr.jpg"), options: PhotoExportOptions(preserveHDR: true))
        let hdrJPGSource = CGImageSourceCreateWithURL(hdrJPG as CFURL, nil)!
        try require(CGImageSourceCopyAuxiliaryDataInfoAtIndex(hdrJPGSource, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil || CGImageSourceCopyAuxiliaryDataInfoAtIndex(hdrJPGSource, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil, "HDR JPEG has no gain map")
        let hdrPixels = floatPixels(CIImage(contentsOf: hdrJPG, options: [.expandToHDR: true])!)
        try require((hdrPixels.max() ?? 0) > 1.1, "HDR JPEG lost extended range")
        // Truncated binary cache must not destroy the authoritative parameters.
        let corrupt = try FileHandle(forWritingTo: PhotoEditStore.sidecar(source))
        try corrupt.truncate(atOffset: savedCrop.payloadOffset + 4); try corrupt.close()
        try require(try PhotoEditStore.read(source)!.document.adjustments == crop.adjustments, "truncated cache lost recipe")
        try require(try PhotoEditStore.preview(source, thumbnail: false) != nil, "cache regeneration failed")
        try require(hash(try Data(contentsOf: source)) == originalHash, "original was modified")
        let recovered = try PhotoEditStore.read(source)!
        try Data([1]).write(to: source)
        do { _ = try PhotoEditStore.save(recovered.document, source: source, expectedToken: recovered.token, cache: false); throw CatalogError(message: "changed source accepted") }
        catch let error as CatalogError { try require(error.message.contains("原片已变化"), error.message) }
        // Full decoding of a real RAW, including a cached completed result.
        if CommandLine.arguments.count > 1 {
            let raw = temp.appendingPathComponent("sample.ARW")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), to: raw)
            let rawHash = hash(try Data(contentsOf: raw))
            var rawDoc = PhotoEditDocument(source: try EditSource.read(raw)); rawDoc.adjustments.exposure = 0.3
            let decoder = CIRAWFilter(imageURL: raw)!
            let size = decoder.nativeSize
            let defaults = try PhotoEditStore.sourceDefaults(raw)
            try require(abs(defaults.temperature-Double(decoder.neutralTemperature)) < 0.001 && abs(defaults.tint-Double(decoder.neutralTint)) < 0.001, "as-shot WB not read from RAW")
            var manual = defaults; manual.asShot = false
            let shotPixels = floatPixels(try PhotoEditStore.render(raw, adjustments: defaults))
            let manualPixels = floatPixels(try PhotoEditStore.render(raw, adjustments: manual))
            let wbDelta = difference(shotPixels,manualPixels)
            print("RAW WB \(defaults.temperature) K / \(defaults.tint), manual transition max delta \(wbDelta)")
            try require(wbDelta < 0.000001, "as-shot/manual WB caused color jump")
            var negative = defaults; negative.exposure = -2
            decoder.exposure = -2
            if decoder.isHighlightRecoverySupported { decoder.isHighlightRecoveryEnabled = true }
            let expected = decoder.outputImage!.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1, kCIInputSaturationKey: 1])
            let newPixels = floatPixels(try PhotoEditStore.render(raw, adjustments: negative))
            try require(difference(newPixels,floatPixels(expected)) < 0.001, "RAW exposure not applied before tone mapping or applied twice")
            let legacyPixels = floatPixels(try PhotoEditStore.render(raw, adjustments: negative, pipelineVersion: 1))
            try require(difference(newPixels,legacyPixels) > 0.01, "RAW exposure still uses legacy SDR adjustment")
            var recover = defaults; recover.highlights = 0.1; recover.shadows = 0.3
            let recoveredPixels = floatPixels(try PhotoEditStore.render(raw, adjustments: recover))
            try require(recoveredPixels.allSatisfy(\.isFinite) && difference(recoveredPixels,shotPixels) > 0.01, "RAW linear hook did not change output")
            let legacyReference = try PhotoEditStore.decode(raw, adjustments: negative, pipelineVersion: 1)
                .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: negative.exposure])
                .applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": negative.highlights, "inputShadowAmount": negative.shadows])
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1, kCIInputSaturationKey: 1])
            try require(difference(legacyPixels,floatPixels(legacyReference)) < 0.001, "legacy appearance changed")
            print("PASS RAW-stage exposure reference, linear highlight/shadow hook, legacy appearance")
            let result = try PhotoEditStore.save(rawDoc, source: raw, expectedToken: nil, cache: true)
            try require(result.document.outputWidth == Int(size.width) && result.document.outputHeight == Int(size.height), "RAW decode not native resolution")
            try require(hash(try Data(contentsOf: raw)) == rawHash, "RAW original changed")
            print("PASS real RAW full-resolution \(size), 16-bit cache, original integrity")
            var legacyDocument = result.document; legacyDocument.pipelineVersion = 1; legacyDocument.adjustments = negative
            let old = try PhotoEditStore.save(legacyDocument, source: raw, expectedToken: result.token, cache: false)
            try require(old.document.pipelineVersion == 1, "legacy pipeline was silently upgraded")
            let legacyPreview = try PhotoEditStore.preview(raw, thumbnail: false)!
            try require(legacyPreview.size.width == size.width, "legacy fallback cache rendering failed")

        }
        if CommandLine.arguments.count > 2 {
            let heic = temp.appendingPathComponent("sample.HEIC")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[2]), to: heic)
            let before = hash(try Data(contentsOf: heic))
            let decoded = try PhotoEditStore.render(heic, adjustments: PhotoAdjustments())
            let properties = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(heic as CFURL, nil)!, 0, nil)! as NSDictionary
            let width = (properties[kCGImagePropertyPixelWidth] as! NSNumber).intValue
            let height = (properties[kCGImagePropertyPixelHeight] as! NSNumber).intValue
            try require(Int(decoded.extent.width * decoded.extent.height) == width * height, "HEIC input downscaled")
            var a = PhotoAdjustments(); a.cropWidth = 0.1; a.cropHeight = 0.1; a.asShot = false; a.temperature = 5200
            _ = try PhotoEditStore.cgImage(PhotoEditStore.render(heic, adjustments: a), sixteenBit: true)
            try require(hash(try Data(contentsOf: heic)) == before, "HEIC original changed")
            print("PASS HEIC full-resolution input \(width) × \(height), white balance/crop rendering")
        }
    }
}
