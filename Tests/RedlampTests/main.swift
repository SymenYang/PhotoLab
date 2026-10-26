import Foundation
import AppKit
import CoreImage
import ImageIO
import CryptoKit

func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw CatalogError(message: message) }
}

@main struct RedlampTests {
    static func main() async throws {
        guard let fixtures = ProcessInfo.processInfo.environment["PHOTOLAB_REDLAMP_FIXTURES"] else {
            throw CatalogError(message: "Set PHOTOLAB_REDLAMP_FIXTURES to a directory with before.jpg (768×576) and full.redrecipe")
        }
        let root = URL(fileURLWithPath: fixtures)
        let directory = try ColorRuntime.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("photo.jpg")
        try FileManager.default.copyItem(at: root.appendingPathComponent("before.jpg"), to: source)
        let sourceHash = SHA256.hash(data: try Data(contentsOf: source))
        var adjustments = PhotoAdjustments(); adjustments.redlamp = .neutral
        try require(!adjustments.hasEffectiveChanges, "neutral Redlamp creates sidecar")
        let oldData = try JSONEncoder().encode(PhotoAdjustments())
        try require(JSONDecoder().decode(PhotoAdjustments.self, from: oldData).redlamp == nil, "legacy parameters not readable")
        let preset = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("full.redrecipe"))) as! [String: Any]
        adjustments.redlamp = try RedlampGrade.imported(preset, original: "电影感", result: ["english": "cinematic", "audit": "test"])
        let originalCurve = adjustments.redlamp!.object["pointCurveRed"] as! [[String: Double]]
        let resident = try RedlampBackend.preparePreview(source)
        let small = try resident.render(adjustments.redlamp!, previewLongEdge: 320)
        try require(max(small.width, small.height) <= 320 && small.bitsPerComponent == 8, "preview is not bounded")
        _ = try resident.render(.neutral, previewLongEdge: 512)
        try require(resident.opens == 1 && resident.previews == 2, "preview reopened input")
        let full = try resident.render(.neutral)
        try require(full.width == 768 && full.height == 576 && full.bitsPerComponent == 16, "preview size leaked into export")
        try adjustments.redlamp!.set("basic.exposure", value: 0.7)
        try require(adjustments.redlamp!.object["pointCurveRed"] as! [[String: Double]] == originalCurve, "manual adjustment lost channel curves")
        try require(adjustments.redlamp!.englishPrompt == "cinematic", "manual adjustment lost provenance")
        let rendered = try PhotoEditStore.render(source, adjustments: adjustments, pipelineVersion: 3)
        try require(rendered.extent.width == 768 && rendered.extent.height == 576, "full resolution lost")
        let sixteen = try PhotoEditStore.cgImage(rendered, sixteenBit: true)
        try require(sixteen.bitsPerComponent == 16, "16-bit rendering lost")
        let recipe = directory.appendingPathComponent("recipe.json"), reference = directory.appendingPathComponent("reference.tiff")
        try adjustments.redlamp!.settings.write(to: recipe)
        try ColorRuntime.run(ColorRuntime.path("redlamp"), ["render", source.path, "--recipe", recipe.path, "--16bit", "-o", reference.path], directory: directory)
        let referenceSource = CGImageSourceCreateWithURL(reference as CFURL, nil)!
        let expected = try pixels(CGImageSourceCreateImageAtIndex(referenceSource, 0, nil)!)
        let actual = try pixels(resident.render(adjustments.redlamp!))
        let maximum = zip(expected, actual).map { abs(Int($0) - Int($1)) }.max()!
        try require(expected.count == actual.count && maximum <= 1, "Native export differs from official CLI: max 8-bit delta \(maximum)")
        print("PASS native export matches official CLI (max 8-bit delta \(maximum))")
        adjustments.cropWidth = 0.5; adjustments.cropHeight = 0.5
        var document = PhotoEditDocument(source: try EditSource.read(source)); document.pipelineVersion = 3; document.adjustments = adjustments
        let saved = try PhotoEditStore.save(document, source: source, expectedToken: nil, cache: true)
        let reopened = try PhotoEditStore.read(source)!
        try require(reopened.document.adjustments == adjustments && reopened.document.pipelineVersion == 3, "recipe/provenance did not roundtrip")
        try require(reopened.document.outputWidth == 384 && reopened.document.outputHeight == 288 && reopened.document.tiffBytes > 0, "geometry or full-resolution cache failed")
        try require(PhotoEditStore.preview(source, thumbnail: false)?.size == CGSize(width: 384, height: 288), "saved preview mismatch")
        let sdrURL = try PhotoEditStore.export(source, to: directory.appendingPathComponent("sdr.jpg"), rotation: 1)
        let fallbackURL = try PhotoEditStore.export(source, to: directory.appendingPathComponent("hdr-preferred.jpg"), rotation: 1, options: PhotoExportOptions(preserveHDR: true))
        let fallbackSource = CGImageSourceCreateWithURL(fallbackURL as CFURL, nil)!
        let fallbackImage = CGImageSourceCreateImageAtIndex(fallbackSource, 0, nil)!
        let sdrImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(sdrURL as CFURL, nil)!, 0, nil)!
        try require(fallbackImage.width == 288 && fallbackImage.height == 384, "HDR fallback lost crop/rotation")
        try require(try pixels(fallbackImage) == pixels(sdrImage), "HDR fallback changed the saved Redlamp edit")
        try require(CGImageSourceCopyAuxiliaryDataInfoAtIndex(fallbackSource, 0, kCGImageAuxiliaryDataTypeHDRGainMap) == nil && CGImageSourceCopyAuxiliaryDataInfoAtIndex(fallbackSource, 0, kCGImageAuxiliaryDataTypeISOGainMap) == nil, "SDR fallback contains an HDR gain map")
        print("PASS HDR preference falls back to edited SDR for Redlamp")
        var reset = saved.document; reset.adjustments = PhotoAdjustments(); reset.adjustments.redlamp = .neutral
        try require(PhotoEditStore.commit(reset, source: source, expectedToken: saved.token, cache: true) == nil, "reset retained sidecar")
        try require(SHA256.hash(data: Data(contentsOf: source)) == sourceHash, "original image changed")
        print("PASS Redlamp 16-bit render, manual + AI recipe, curves, crop, save/cache/reopen/reset, original integrity")
        let task = Task.detached {
            try ColorRuntime.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], directory: directory)
        }
        try await Task.sleep(for: .milliseconds(400))
        let start = Date(); task.cancel()
        do { try await task.value; throw CatalogError(message: "cancelled process completed") } catch is CancellationError { }
        try require(Date().timeIntervalSince(start) < 4, "cancellation did not terminate process")
        print("PASS cancelled process terminates promptly")
        if CommandLine.arguments.contains("--benchmark") { try benchmark(root) }
    }
    static func benchmark(_ root: URL) throws {
        let source = root.appendingPathComponent("test_photo/B0001166.HEIC")
        let start = Date(), engine = try RedlampBackend.preparePreview(source)
        let opened = Date().timeIntervalSince(start) * 1000
        var grade = RedlampGrade.neutral, samples: [Double] = [], first = 0.0
        for index in 0..<16 {
            try grade.set("basic.exposure", value: Double(index) / 20)
            let began = Date()
            try autoreleasepool {
                let frame = try engine.render(grade, previewLongEdge: 1536)
                try require(max(frame.width, frame.height) <= 1536, "large preview rendered at full size")
            }
            let duration = Date().timeIntervalSince(began) * 1000
            if index == 0 { first = duration } else { samples.append(duration) }
        }
        let began = Date()
        let full = try engine.render(grade)
        try require(CGSize(width: full.width, height: full.height) == engine.size && full.bitsPerComponent == 16, "large export lost resolution")
        let exportMilliseconds = Date().timeIntervalSince(began) * 1000
        var controls: [String: Any] = [:]
        for key in ["basic.shadows", "basic.saturation", "mixer.hue.blue", "basic.texture", "basic.clarity", "basic.dehaze"] {
            var values: [Double] = [], control = RedlampGrade.neutral
            for index in 0..<8 {
                try control.set(key, value: Double(index + 1) * 5)
                let started = Date()
                _ = try autoreleasepool { try engine.render(control, previewLongEdge: 1536) }
                values.append(Date().timeIntervalSince(started) * 1000)
            }
            controls[key] = ["first_ms": values[0], "warm_median_ms": values.dropFirst().sorted()[3], "max_ms": values.max()!]
        }
        let output: [String: Any] = ["source": source.lastPathComponent, "width": full.width, "height": full.height,
            "open_ms": opened, "first_preview_ms": first, "preview_edge": 1536, "preview_samples_ms": samples,
            "preview_median_ms": samples.sorted()[samples.count / 2], "preview_max_ms": samples.max()!,
            "export_ms": exportMilliseconds, "other_controls": controls, "opens": engine.opens, "renders": engine.previews]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("build/redlamp-preview-benchmark.json"))
        print(String(decoding: data, as: UTF8.self))
    }
    static func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw CatalogError(message: "Cannot create comparison context")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}
