import Foundation
import AppKit
import CoreImage
import ImageIO
import CryptoKit
import SwiftUI

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CatalogError(message: message) }
}

@main struct ColorControlsTests {
    static func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }
    static func mean(_ pixels: [UInt8]) -> [Double] {
        (0..<3).map { channel in stride(from: channel, to: pixels.count, by: 4).reduce(0.0) { $0 + Double(pixels[$1]) } / Double(pixels.count / 4) }
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if CommandLine.arguments.contains("--real-ai") {
            let start = Date()
            let raw = root.appendingPathComponent("test_photo/B0001166.3FR")
            let grade = try RedlampBackend.generate(raw, prompt: "A natural cinematic look, gentle contrast, soft highlights, slightly warm colors. Preserve detail.") { message, _ in
                print(String(format: "%.1fs %@", Date().timeIntervalSince(start), message)); fflush(stdout)
            }
            try grade.validate()
            try JSONEncoder().encode(grade).write(to: root.appendingPathComponent("build/raw-ai-validation.json"))
            print(String(format: "PASS real JarvisArt on 102MP 3FR: %.1fs, %d scalar parameters", Date().timeIntervalSince(start), grade.values.count))
            return
        }
        let directory = try ColorRuntime.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("test.png")
        let context = CGContext(data: nil, width: 128, height: 96, bitsPerComponent: 8, bytesPerRow: 512,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<96 { for x in 0..<128 {
            let v = 0.15 + 0.65 * Double(x + y) / 222
            context.setFillColor(CGColor(red: v * 1.15, green: v, blue: v * 0.75, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        } }
        let destination = CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        try require(CGImageDestinationFinalize(destination), "fixture encoding")
        let original = try Data(contentsOf: source)
        let engine = try RedlampBackend.preparePreview(source)
        let neutral = pixels(try engine.render(.neutral))
        var grade = RedlampGrade.neutral
        try grade.set("wb.temperature", value: 5500)
        try require(grade.whiteBalance == "custom", "temperature must activate custom WB")
        try require(pixels(engine.render(grade)) == neutral, "RGB reference white balance changed neutral pixels")
        try grade.set("wb.temperature", value: 9500)
        let warm = mean(pixels(try engine.render(grade)))
        try grade.set("wb.temperature", value: 3000)
        let cool = mean(pixels(try engine.render(grade)))
        try require(warm[0] / warm[2] > cool[0] / cool[2] + 0.1, "RGB temperature has no effect or reversed direction")
        try grade.set("wb.temperature", value: 5500)
        try grade.set("wb.tint", value: 80)
        let magenta = mean(pixels(try engine.render(grade)))
        try grade.set("wb.tint", value: -80)
        let green = mean(pixels(try engine.render(grade)))
        try require((magenta[0] + magenta[2]) / magenta[1] > (green[0] + green[2]) / green[1], "RGB tint direction")
        try grade.setField("whiteBalance", value: "asShot")
        try require(pixels(engine.render(grade)) == neutral, "as-shot did not ignore stored custom WB")
        grade = .neutral; try grade.setField("whiteBalance", value: "auto")
        let autoPixels = pixels(try engine.render(grade))
        let resolvedBalance = engine.whiteBalance
        try grade.set("wb.temperature", value: resolvedBalance["wb.temperature"]!)
        try grade.set("wb.tint", value: resolvedBalance["wb.tint"]!)
        try require(pixels(engine.render(grade)) == autoPixels, "auto-to-custom changed white balance")
        let automatic = mean(autoPixels), before = mean(neutral)
        try require(abs(automatic[0] - automatic[2]) < abs(before[0] - before[2]), "RGB auto WB did not reduce cast")
        print("PASS RGB temperature, tint, neutral reference, as-shot and automatic white balance")

        grade = .neutral; grade.originalPrompt = "preserve provenance"
        let curve = [GradeCurvePoint(x: 0, y: 0.1), .init(x: 0.4, y: 0.6), .init(x: 1, y: 0.9)]
        for key in RedlampGrade.curveKeys { try grade.setCurve(key, points: curve) }
        let samples = NativeColorEngine.curveSamples([.init(x: 0, y: 0), .init(x: 0.5, y: 0.7), .init(x: 1, y: 1)])
        try require(samples.count == 129 && abs(samples[64].y - 0.7) < 0.00001, "curve graph does not use renderer interpolation")
        let originalGrade = grade
        do {
            try grade.setCurve("pointCurve", points: [.init(x: 0.5, y: 0), .init(x: 0.5, y: 1)])
            throw CatalogError(message: "duplicate curve coordinates accepted")
        } catch { try require(grade == originalGrade, "invalid curve partially mutated grade") }
        try grade.set("grading.shadows.hue", value: 220)
        try grade.set("grading.shadows.saturation", value: 30)
        try grade.set("detail.sharpen.amount", value: 90)
        try grade.set("detail.noise.luminance", value: 20)
        try grade.set("effects.vignette.amount", value: -40)
        try grade.set("effects.grain.amount", value: 30)
        try require(grade.curve("pointCurveBlue") == curve && grade.originalPrompt == "preserve provenance", "manual edit dropped curve or provenance")
        try require(pixels(engine.render(grade)) != neutral, "extended controls did not render")
        var bw = RedlampGrade.neutral; try bw.setField("treatment", value: "blackAndWhite")
        let grey = mean(pixels(try engine.render(bw)))
        try require(abs(grey[0] - grey[1]) < 1 && abs(grey[1] - grey[2]) < 1, "black and white switch did not render")
        var adjustments = PhotoAdjustments(); adjustments.redlamp = grade
        var doc = PhotoEditDocument(source: try EditSource.read(source)); doc.pipelineVersion = 3; doc.adjustments = adjustments
        _ = try PhotoEditStore.save(doc, source: source, expectedToken: nil, cache: true)
        try require(PhotoEditStore.read(source)?.document.adjustments == adjustments, "extended settings did not roundtrip")
        try require(Data(contentsOf: source) == original, "original image changed")
        print("PASS curve validation, all four channels, extended rendering, B&W, provenance and sidecar roundtrip")

        for filename in ["DSC00001.ARW", "B0001166.3FR"] {
            let raw = root.appendingPathComponent("test_photo/" + filename)
            guard FileManager.default.fileExists(atPath: raw.path) else { continue }
            let start = Date()
            let input = try RedlampBackend.modelInput(raw, directory: directory)
            let inputImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(input as CFURL, nil)!, 0, nil)!
            try require(max(inputImage.width, inputImage.height) <= 1536, "AI input not bounded")
            let base = try RedlampBackend.workingBase(raw, maxLongEdge: 2048)!
            let sourceImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(base.image as CFURL, nil)!, 0, nil)!
            try require(max(sourceImage.width, sourceImage.height) <= 2048 && sourceImage.bitsPerComponent == 16, "RAW base not bounded 16-bit")
            let native = try RedlampBackend.preparePreview(raw)
            try require(native.sourceSize == base.sourceSize && max(native.size.width, native.size.height) <= 2048, "RAW logical resolution lost")
            let session = PhotoEditSession(source: raw)
            var settings = PhotoAdjustments(); settings.redlamp = grade
            let frame = try await session.render(settings, pipelineVersion: 3, previewLongEdge: 1024)
            try require(frame.size == base.sourceSize && max(frame.representations[0].pixelsWide, frame.representations[0].pixelsHigh) <= 1024, "RAW editor size mismatch")
            let elapsed = Date().timeIntervalSince(start)
            print(String(format: "RAW %@ model input + preview: %.2fs, logical %.0fx%.0f, base %dx%d", filename, elapsed, base.sourceSize.width, base.sourceSize.height, sourceImage.width, sourceImage.height))
            let generated = try RedlampBackend.generate(raw, prompt: "fixture") { _, _ in }
            try require(generated.values["basic.exposure"] == 0.3, "RAW AI fixture flow failed")
            if filename.hasSuffix("ARW") {
                // A tighter crop asks for a larger base, while keeping full-size geometry.
                settings.cropWidth = 0.5; settings.cropHeight = 0.5
                let crop = try await session.render(settings, pipelineVersion: 3, previewLongEdge: 1536)
                try require(crop.size == CGSize(width: base.sourceSize.width / 2, height: base.sourceSize.height / 2), "crop changed logical size")
                let diagnostics = await session.previewDiagnostics()
                try require(diagnostics.opens == 1, "replacement preview session did not open once")
                let full = try RedlampBackend.render(raw, grade: grade)
                try require(full.extent.size == base.sourceSize, "RAW full-resolution export used preview base")
            }
        }
        let cancelled = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try RedlampBackend.modelInput(source, directory: directory)
        }
        do { _ = try await cancelled.value; throw CatalogError(message: "Cancelled preparation completed") }
        catch is CancellationError { }
        print("PASS RAW AI pipeline (fixture inference), crop refinement, full-resolution output and cancellation")
        try await editorChecks(source)
    }
    @MainActor static func editorChecks(_ source: URL) async throws {
        let editor = PhotoEditorModel()
        editor.open([EditablePhoto(id: "test", name: "test", sources: [source], rotation: 0)], selectedID: "test")
        let deadline = Date().addingTimeInterval(20)
        while !editor.canEdit || editor.rendering || editor.image == nil {
            try require(Date() < deadline, "editor open timeout")
            try await Task.sleep(for: .milliseconds(20))
        }
        let before = editor.parameters
        editor.setColorField("treatment", value: "blackAndWhite")
        editor.undo(); try require(editor.parameters == before, "B&W undo")
        editor.redo(); try require(editor.parameters.redlamp?.blackAndWhite == true, "B&W redo")
        let beforeCurve = editor.parameters
        editor.sliderEditing(true)
        editor.setColorCurve("pointCurve", points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.7), .init(x: 1, y: 1)])
        editor.setColorCurve("pointCurve", points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.8), .init(x: 1, y: 1)])
        editor.sliderEditing(false)
        editor.undo(); try require(editor.parameters == beforeCurve, "curve drag undo was not grouped")
        editor.redo(); try require(editor.parameters.redlamp?.curve("pointCurve")[1].y == 0.8, "curve redo")
        editor.setColorField("whiteBalance", value: "auto")
        while editor.rendering { try await Task.sleep(for: .milliseconds(20)) }
        let resolved = editor.renderedColorWhiteBalance
        editor.setColorField("whiteBalance", value: "custom")
        try require(editor.parameters.redlamp?.values["wb.temperature"] == resolved["wb.temperature"] && editor.parameters.redlamp?.values["wb.tint"] == resolved["wb.tint"], "editor auto-to-custom did not preserve resolved balance")
        if CommandLine.arguments.contains("--snapshot") {
            _ = NSApplication.shared
            editor.tab = "manual"
            let view = NSHostingView(rootView: PhotoEditorView(editor: editor, inspectorOnly: true))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 350, height: 1100), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.frame = NSRect(x: 0, y: 0, width: 350, height: 1100)
            view.layoutSubtreeIfNeeded(); view.display()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/private/tmp/photolab-manual-panel.png"))
            }
            let curve = NSHostingView(rootView: GradeCurveEditor(points: .constant([.init(x: 0, y: 0), .init(x: 0.5, y: 0.7), .init(x: 1, y: 1)]), editing: { _ in }).padding(16))
            window.contentView = curve; curve.frame = NSRect(x: 0, y: 0, width: 350, height: 430)
            curve.layoutSubtreeIfNeeded(); curve.display()
            if let bitmap = curve.bitmapImageRepForCachingDisplay(in: curve.bounds) {
                curve.cacheDisplay(in: curve.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/private/tmp/photolab-curve-panel.png"))
            }
        }
        editor.close()
        print("PASS editor B&W, grouped curve undo/redo and auto-to-custom white balance")
    }
}
