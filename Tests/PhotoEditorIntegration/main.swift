import Foundation
import Translation
import AppKit
import SwiftUI

@main struct EditorIntegration {
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(40)
        while !ready() {
            if Date() > deadline { throw CatalogError(message: "Editor integration timeout") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--preview-benchmark") {
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let session = PhotoEditSession(source: root.appendingPathComponent("test_photo/B0001166.HEIC"))
            var (settings, _, _, _) = try await session.load()
            var samples: [Double] = [], cold = 0.0
            for index in 0..<16 {
                try settings.redlamp!.set("basic.exposure", value: Double(index) / 20)
                let began = Date()
                let frame = try await session.render(settings, previewLongEdge: 1536)
                let elapsed = Date().timeIntervalSince(began) * 1000
                guard frame.size == CGSize(width: 8742, height: 11656),
                      max(frame.representations[0].pixelsWide, frame.representations[0].pixelsHigh) <= 1536 else {
                    throw CatalogError(message: "Large preview bitmap/logical size mismatch")
                }
                if index == 0 { cold = elapsed } else { samples.append(elapsed) }
            }
            let stats = await session.previewDiagnostics()
            guard stats.opens == 1, stats.renders == 16 else { throw CatalogError(message: "Large preview did not retain engine") }
            let report: [String: Any] = ["stage": "PhotoEditSession including decode, native render, geometry, color conversion and NSBitmapImageRep; excluding onscreen presentation",
                "cold_ms": cold, "warm_median_ms": samples.sorted()[samples.count / 2], "warm_max_ms": samples.max()!,
                "samples_ms": samples, "edge": 1536, "opens": stats.opens]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: root.appendingPathComponent("build/editor-preview-benchmark.json"))
            print(String(decoding: data, as: UTF8.self))
            return
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("photolab-editor-state-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let first = temp.appendingPathComponent("one.JPG"), second = temp.appendingPathComponent("two.JPG")
        let sample = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.copyItem(at: sample, to: first)
        try FileManager.default.copyItem(at: sample, to: second)
        if CommandLine.arguments.contains("--redlamp") { try await redlamp(first, directory: temp); return }
        for source in [first, second] {
            _ = try PhotoEditStore.save(PhotoEditDocument(source: EditSource.read(source)), source: source, expectedToken: nil, cache: false)
        }
        if CommandLine.arguments.contains("--real-crop") {
            var evaluations = 0
            let limit = CommandLine.arguments.contains("--quick-crop") ? 30 : 90
            let top = try await AutoCropRunner().run(source: first, settings: PhotoAdjustments(), pipeline: 2, rotation: 0, aspect: 0.75, area: 0.3, budget: limit) { evaluations = $0 }
            guard top.count == 5, evaluations >= 10, evaluations <= limit else { throw CatalogError(message: "Real crop search failed") }
            for c in top { print("REAL CROP \(c.score) \(c.pixels) area=\(c.rect.width*c.rect.height)") }
            print("PASS real Metal crop search: \(evaluations) evaluations, 5 portrait candidates")
            return
        }
        let editor = PhotoEditorModel()
        var refreshes = 0
        editor.onChange = { refreshes += 1 }
        let items = [EditablePhoto(id: "one", name: "one", sources: [first], rotation: 0), EditablePhoto(id: "two", name: "two", sources: [second], rotation: 0)]
        // Closing/reopening before async source discovery finishes must not publish stale state.
        editor.open(items, selectedID: "two")
        editor.close()
        editor.open(items, selectedID: "one")
        try await wait { editor.canEdit && editor.image != nil && !editor.rendering }
        guard editor.current?.id == "one", editor.source == first else { throw CatalogError(message: "Stale source discovery replaced reopened photo") }
        let cancelledLookup = Task { try await PhotoEditStore.findPreferredSource([first]) }
        cancelledLookup.cancel()
        do { _ = try await cancelledLookup.value; throw CatalogError(message: "Cancelled source discovery completed") } catch is CancellationError { }
        print("PASS async source discovery cancellation and close/reopen isolation")
        editor.tab = "crop"
        try await wait { !editor.rendering }
        editor.cropRatio = "4:3"
        guard editor.cropAspect == 4.0/3 else { throw CatalogError(message: "Landscape aspect") }
        editor.cropRatio = "3:4"
        guard editor.cropAspect == 3.0/4 else { throw CatalogError(message: "Portrait aspect") }
        let impossible = AutoCropLimits(size: CGSize(width: 4000,height: 3000), aspect: 0.75, area: 0.9)
        guard !impossible.feasible else { throw CatalogError(message: "Impossible area accepted") }
        guard !AutoCropLimits(size: CGSize(width: 100,height: 100), aspect: 1.3, area: 0.76).feasible else { throw CatalogError(message: "Pixel rounding violated minimum area") }
        let limits = AutoCropLimits(size: CGSize(width: 4000,height: 3000), aspect: 0.75, area: 0.3)
        guard limits.feasible && limits.minimum.width*limits.minimum.height >= 3600000 else { throw CatalogError(message: "Wrong output lower bound") }
        var progress = 0
        let suggestions = try await AutoCropRunner().run(source: first, settings: PhotoAdjustments(), pipeline: 2, rotation: 1, aspect: 0.75, area: 0.3, scorer: { url in
            let data = try Data(contentsOf: url)
            guard let image = NSImage(data: data), max(image.size.width,image.size.height) <= 961 else { throw CatalogError(message: "Bad scoring image") }
            return Double(data.count % 1000)/1000
        }) { progress = $0 }
        guard suggestions.count == 5, progress > 30, progress <= 90 else { throw CatalogError(message: "Search budget/results/progress") }
        for c in suggestions {
            guard c.rect.minX >= 0, c.rect.minY >= 0, c.rect.maxX <= 1.000001, c.rect.maxY <= 1.000001,
                  c.rect.width*c.rect.height >= 0.3, abs(c.pixels.width/c.pixels.height-0.75) < 0.001 else { throw CatalogError(message: "Invalid search crop") }
        }
        var manual = PhotoAdjustments(); manual.cropX = 0.2; manual.cropY = 0.15; manual.cropWidth = 0.4; manual.cropHeight = 0.6
        var originalScore = -1.0
        let manualResult = try await AutoCropRunner().run(source: first, settings: manual, pipeline: 2, rotation: 0, aspect: 1, area: 1, manualOnly: true, baseline: { originalScore = $0 }, scorer: { url in
            let im = NSImage(contentsOf: url)!
            return im.size.width > im.size.height ? 0.8 : 0.2
        }) { _ in }
        guard originalScore == 0.8, manualResult.count == 1, abs(manualResult[0].rect.width-0.4) < 0.001, abs(manualResult[0].rect.height-0.6) < 0.001 else { throw CatalogError(message: "Manual score did not use full original baseline or selected crop") }
        var baselineAgain = -1.0
        _ = try await AutoCropRunner().run(source: first, settings: PhotoAdjustments(), pipeline: 2, rotation: 0, aspect: 1, area: 1, manualOnly: true, baseline: { baselineAgain = $0 }, scorer: { url in
            let im = NSImage(contentsOf: url)!; return im.size.width > im.size.height ? 0.8 : 0.2
        }) { _ in }
        guard baselineAgain == originalScore else { throw CatalogError(message: "Baseline depends on current crop") }
        editor.autoCrop.baselineScore = originalScore; editor.autoCrop.manualScore = 0.5
        editor.displayCrop = CGRect(x: 0.1,y: 0.1,width: 0.5,height: 0.5)
        guard editor.autoCrop.manualScore == nil, editor.autoCrop.baselineScore == originalScore else { throw CatalogError(message: "Crop drag score invalidation") }
        print("PASS manual crop scoring, original-frame baseline independence and stale score invalidation")
        editor.autoCrop.results = suggestions; editor.autoCrop.running = true; editor.autoCrop.count = 7; editor.autoCrop.baselineScore = 0.4
        editor.autoCrop.stop()
        guard !editor.autoCrop.running, editor.autoCrop.results.count == 5, editor.autoCrop.count == 7, editor.autoCrop.baselineScore == 0.4 else { throw CatalogError(message: "Stop discarded partial results") }
        editor.autoCrop.results = suggestions
        editor.cropRatio = "4:3"
        guard editor.autoCrop.results.isEmpty else { throw CatalogError(message: "Aspect change retained stale candidates") }
        editor.autoCrop.results = suggestions
        editor.rotateCrop(\.straighten, value: 1)
        guard editor.autoCrop.results.isEmpty else { throw CatalogError(message: "Rotation retained stale candidates") }
        editor.rotateCrop(\.straighten, value: 0)
        editor.cropRatio = "自由"
        let cancelled = Task { try await AutoCropRunner().run(source: first, settings: PhotoAdjustments(), pipeline: 2, rotation: 0, aspect: 1, area: 0.3, scorer: { _ in
            try await Task.sleep(for: .seconds(20)); return 0.5
        }) { _ in } }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw CatalogError(message: "Cancelled search completed") } catch is CancellationError { }
        print("PASS auto crop portrait/landscape, area feasibility, top5, progress, bounds, invalidation and cancellation")
        editor.displayCrop = CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.7)
        guard editor.parameters == PhotoAdjustments(), !editor.rendering else { throw CatalogError(message: "Crop drag rendered or committed draft") }
        editor.cancelCrop()
        guard editor.parameters == PhotoAdjustments(), editor.cropDraft == nil else { throw CatalogError(message: "Cancel crop changed parameters") }
        editor.tab = "crop"
        try await wait { !editor.rendering }
        let rotationBase = editor.image!
        for angle in [-12.0, -4.5, 0, 7.2, 15] {
            editor.rotateCrop(\.straighten, value: angle)
            guard editor.image === rotationBase, !editor.rendering else { throw CatalogError(message: "Rotation slider triggered RAW rendering") }
        }
        editor.rotateCrop(\.straighten, value: 7.2)
        editor.cropRatio = "1:1"; editor.fitCropRatio()
        let box = editor.displayCrop, size = editor.cropCanvasSize
        guard abs(box.width*size.width-box.height*size.height) < 0.01 else { throw CatalogError(message: "Square crop uses incorrect image aspect") }
        editor.applyCrop()
        try await wait { !editor.rendering }
        guard editor.image!.size.width == editor.image!.size.height, editor.undoValues.count == 1 else { throw CatalogError(message: "Crop result/undo mismatch") }
        editor.undo()
        try await wait { !editor.rendering }
        guard editor.parameters == PhotoAdjustments() else { throw CatalogError(message: "Crop undo failed") }
        editor.tab = "crop"
        try await wait { !editor.rendering }
        guard editor.displayCrop.width == 1 else { throw CatalogError(message: "Reopened crop lost full image") }
        editor.cancelCrop()
        let testRect = CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5)
        for turns in 0..<4 {
            let roundtrip = CropGeometry.rotated(CropGeometry.rotated(testRect, turns: turns), turns: (4-turns)%4)
            guard abs(roundtrip.minX-testRect.minX) < 1e-8 && abs(roundtrip.minY-testRect.minY) < 1e-8 else { throw CatalogError(message: "Rotated crop coordinate roundtrip") }
        }
        for handle in -1..<8 {
            for dx in [-2.0, -0.2, 0.2, 2.0] {
                for ratio in [nil, 1.0, 1.5, 0.5] as [Double?] {
                    let start = ratio.map { CropGeometry.fitted(testRect, ratio: $0) } ?? testRect
                    let r = CropGeometry.dragged(start, handle: handle, delta: CGSize(width: dx, height: -dx), ratio: ratio)
                    guard r.minX >= -1e-8, r.minY >= -1e-8, r.maxX <= 1+1e-8, r.maxY <= 1+1e-8, r.width > 0, r.height > 0 else { throw CatalogError(message: "Crop drag escaped bounds") }
                    if let ratio { guard abs(r.width/r.height-ratio) < 1e-7 else { throw CatalogError(message: "Drag changed locked ratio") } }
                }
            }
        }
        print("PASS crop draft/apply/cancel/reopen/undo, rotated coordinates and all drag handles")
        editor.sliderEditing(true)
        editor.parameters.exposure = 0.5
        editor.parameters.exposure = 0.9
        editor.sliderEditing(false)
        guard editor.undoValues.count == 1 else { throw CatalogError(message: "Slider drag must be one undo") }
        editor.undo()
        guard editor.parameters.exposure == 0 else { throw CatalogError(message: "Undo did not restore original") }
        editor.redo()
        guard editor.parameters.exposure == 0.9 else { throw CatalogError(message: "Redo failed") }
        try await wait { !editor.unsaved && !editor.saving }
        guard try PhotoEditStore.read(first)?.document.adjustments.exposure == 0.9 else { throw CatalogError(message: "Autosave did not persist recipe") }
        editor.parameters.saturation = 0.6
        // Complete while an autosave is pending, then switch photo.
        editor.complete(next: 1)
        try await wait { editor.index == 1 && editor.canEdit && !editor.finishing && !editor.rendering }
        guard editor.parameters == PhotoAdjustments(), editor.undoValues.isEmpty,
              let saved = try PhotoEditStore.read(first), saved.document.adjustments.saturation == 0.6,
              saved.document.tiffBytes > 0 else { throw CatalogError(message: "Complete/switch lost parameters or inherited previous photo state") }
        editor.complete()
        try await wait { !editor.isPresented }
        guard try PhotoEditStore.read(second) == nil else { throw CatalogError(message: "Unedited photo acquired sidecar") }
        editor.open(items, selectedID: "one")
        try await wait { editor.canEdit && !editor.rendering && editor.image != nil }
        guard editor.parameters.exposure == 0.9 && editor.parameters.saturation == 0.6 else { throw CatalogError(message: "Reopen lost saved adjustments") }
        editor.showOriginal = true
        try await wait { !editor.rendering }
        guard editor.parameters.exposure == 0.9 else { throw CatalogError(message: "Original comparison modified recipe") }
        // Another writer must not be overwritten, and the editor must retain its unsaved work.
        var external = saved.document; external.adjustments.exposure = 1.5
        _ = try PhotoEditStore.save(external, source: first, expectedToken: saved.token, cache: false)
        editor.parameters.exposure = 0.2
        editor.complete()
        try await wait { !editor.finishing && editor.error != nil }
        guard editor.isPresented && editor.unsaved && editor.parameters.exposure == 0.2,
              try PhotoEditStore.read(first)?.document.adjustments.exposure == 1.5 else { throw CatalogError(message: "Conflict failed to retain user work") }
        editor.close()
        guard refreshes > 0 else { throw CatalogError(message: "Browser never refreshed") }
        print("PASS editor autosave, grouped undo/redo, pending-save completion, navigation, reopen, compare, conflict retention")
        editor.open(items, selectedID: "one")
        try await wait { editor.canEdit && !editor.rendering && editor.image != nil }
        editor.resetAdjustments()
        try await wait { !editor.unsaved && !editor.saving }
        guard try PhotoEditStore.read(first) == nil, PhotoEditStore.preferredSource([first,second]) == nil else { throw CatalogError(message: "Reset retained sidecar/preference") }
        editor.parameters.exposure = 0.4
        try await wait { !editor.unsaved && !editor.saving }
        guard try PhotoEditStore.read(first) != nil else { throw CatalogError(message: "Editing after reset did not recreate sidecar") }
        editor.undo()
        try await wait { !editor.unsaved && !editor.saving }
        guard try PhotoEditStore.read(first) == nil else { throw CatalogError(message: "Undo-all retained sidecar") }
        editor.complete()
        try await wait { !editor.isPresented }
        print("PASS reset/undo removes neutral sidecars, clears format preference, and supports re-editing")
        if CommandLine.arguments.count > 2 {
            let raw = temp.appendingPathComponent("raw.ARW")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[2]), to: raw)
            let rawDefaults = try PhotoEditStore.sourceDefaults(raw)
            let rawItems = [EditablePhoto(id: "raw", name: "raw", sources: [raw], rotation: 0)]
            editor.open(rawItems, selectedID: "raw")
            try await wait { editor.canEdit && !editor.rendering && editor.image != nil }
            guard editor.parameters.redlamp == .neutral, !editor.unsaved, editor.pipelineVersion == 3 else { throw CatalogError(message: "RAW defaults/display or dirty state incorrect") }
            editor.complete()
            try await wait { !editor.isPresented }
            guard try PhotoEditStore.read(raw) == nil else { throw CatalogError(message: "Reading WB caused an unnecessary edit file") }
            var oldDoc = PhotoEditDocument(source: try EditSource.read(raw)); oldDoc.pipelineVersion = 1
            _ = try PhotoEditStore.save(oldDoc, source: raw, expectedToken: nil, cache: false)
            editor.open(rawItems, selectedID: "raw")
            try await wait { editor.canEdit && !editor.rendering && editor.image != nil }
            guard editor.pipelineVersion == 1, editor.parameters == rawDefaults, !editor.unsaved else { throw CatalogError(message: "Legacy RAW silently changed or WB remained 6500") }
            editor.setAsShot(false)
            guard !editor.parameters.asShot, editor.parameters.temperature == rawDefaults.temperature, editor.parameters.tint == rawDefaults.tint else { throw CatalogError(message: "Manual WB does not begin at as-shot values") }
            editor.parameters.temperature = 7200
            editor.setAsShot(true)
            guard editor.parameters == rawDefaults else { throw CatalogError(message: "As-shot toggle did not restore camera values") }
            editor.undo()
            guard !editor.parameters.asShot, editor.parameters.temperature == 7200 else { throw CatalogError(message: "WB undo lost manual settings") }
            editor.resetAdjustments()
            guard editor.parameters.redlamp == .neutral, !editor.parameters.hasEffectiveChanges else { throw CatalogError(message: "Reset did not switch to neutral Redlamp") }
            editor.pipelineVersion = 2
            editor.complete()
            try await wait { !editor.isPresented }
            guard try PhotoEditStore.read(raw) == nil else { throw CatalogError(message: "RAW reset retained an identity edit file") }
            editor.open(rawItems, selectedID: "raw")
            try await wait { editor.canEdit && !editor.rendering && editor.image != nil }
            guard editor.pipelineVersion == 3, editor.parameters.redlamp == .neutral else { throw CatalogError(message: "RAW upgrade/WB reopen mismatch") }
            editor.close()
            print("PASS actual RAW white balance, seamless manual start, reset/undo, clean opening and explicit legacy upgrade")
        }

    }
    @MainActor static func redlamp(_ source: URL, directory: URL) async throws {
        let session = PhotoEditSession(source: source)
        let (settings, _, _, _) = try await session.load()
        let small = try await session.render(settings, previewLongEdge: 512)
        let large = try await session.render(settings, previewLongEdge: 1024)
        let stats = await session.previewDiagnostics()
        guard small.size == large.size, max(small.representations[0].pixelsWide, small.representations[0].pixelsHigh) <= 512,
              stats.opens == 1, stats.renders == 2 else { throw CatalogError(message: "Preview dimensions/session reuse failed: \(small.size), \(large.size), bitmap \(small.representations[0].pixelsWide)x\(small.representations[0].pixelsHigh), stats \(stats)") }
        let editor = PhotoEditorModel(), items = [EditablePhoto(id: "color", name: "color", sources: [source], rotation: 0)]
        editor.open(items, selectedID: "color")
        try await wait { editor.canEdit && !editor.rendering && editor.image != nil }
        guard editor.tab == "ai", editor.parameters.redlamp == .neutral, !editor.unsaved else { throw CatalogError(message: "New editor does not default to neutral AI tab") }
        let untranslated = "森山大道的风格，保留肤色"
        editor.colorPrompt = untranslated
        editor.startAI()
        guard !editor.aiRunning, editor.needsTranslation else { throw CatalogError(message: "Chinese input must not generate") }
        editor.startTranslation()
        guard editor.isTranslating, editor.translationConfiguration != nil else { throw CatalogError(message: "Translation did not start") }
        await editor.finishTranslation(prompt: untranslated) { "Apple output, unchanged" }
        guard editor.colorPrompt == "Apple output, unchanged", !editor.needsTranslation, !editor.aiRunning,
              editor.parameters.redlamp == .neutral, !editor.unsaved else { throw CatalogError(message: "Translation must only replace prompt, without generating or changing edits") }
        editor.colorPrompt = untranslated; editor.startTranslation()
        await editor.finishTranslation(prompt: untranslated) { throw CatalogError(message: "translation failure") }
        guard editor.colorPrompt == untranslated, editor.aiError != nil, !editor.aiRunning else { throw CatalogError(message: "Translation failure changed input") }
        editor.startTranslation()
        await editor.finishTranslation(prompt: untranslated) {
            editor.cancelAI()
            return "stale cancelled output"
        }
        guard editor.colorPrompt == untranslated, !editor.aiRunning else { throw CatalogError(message: "Cancelled translation overwrote input") }
        editor.startTranslation()
        await editor.finishTranslation(prompt: untranslated) {
            editor.colorPrompt = "new input"
            return "stale output"
        }
        guard editor.colorPrompt == "new input", !editor.aiRunning else { throw CatalogError(message: "Stale translation overwrote input") }
        guard ColorPrompt.containsChinese("電影感"), ColorPrompt.containsChinese("cinematic 肤色"),
              !ColorPrompt.containsChinese("Daido Moriyama style") else { throw CatalogError(message: "Language routing failed") }
        print("PASS Apple translation state: explicit two steps, unchanged output, failure, cancellation, stale input, Chinese generation guard")
        if CommandLine.arguments.contains("--apple-translation") {
            let sourceLanguage = Locale.Language(identifier: "zh-Hans"), targetLanguage = Locale.Language(identifier: "en")
            guard await LanguageAvailability().status(from: sourceLanguage, to: targetLanguage) == .installed else {
                throw CatalogError(message: "Install Apple Chinese/English resources before running --apple-translation")
            }
            let translation = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
            editor.colorPrompt = untranslated; editor.startTranslation()
            await editor.translate(using: translation)
            guard !editor.aiRunning, editor.aiError == nil, !editor.needsTranslation,
                  editor.colorPrompt != untranslated, editor.parameters.redlamp == .neutral, !editor.unsaved else {
                throw CatalogError(message: "Real Apple translation failed: \(editor.aiError ?? editor.colorPrompt)")
            }
            print("PASS real Apple translation, no automatic grading: \(editor.colorPrompt)")
        }
        if CommandLine.arguments.contains("--snapshot") {
            _ = NSApplication.shared
            editor.colorPrompt = "电影感，保留自然肤色，柔和高光，冷色阴影"
            let view = NSHostingView(rootView: PhotoEditorView(editor: editor, inspectorOnly: true))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 350, height: 950), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.frame = NSRect(x: 0, y: 0, width: 350, height: 950)
            view.layoutSubtreeIfNeeded(); view.display()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/private/tmp/photolab-color-panel.png"))
            }
        }
        editor.tab = "manual"
        editor.sliderEditing(true); editor.setColor("basic.exposure", value: 0.4); editor.setColor("basic.exposure", value: 0.7); editor.sliderEditing(false)
        guard editor.undoValues.count == 1 else { throw CatalogError(message: "Redlamp slider undo not grouped") }
        editor.undo(); guard editor.parameters.redlamp == .neutral else { throw CatalogError(message: "Redlamp undo failed") }
        editor.redo()
        try await wait { !editor.rendering && !editor.unsaved && !editor.saving }
        editor.updatePreviewSize(512)
        try await wait { !editor.rendering }
        guard max(editor.previewPixels.width, editor.previewPixels.height) <= 512 else { throw CatalogError(message: "Editor ignored preview size") }
        guard editor.parameters.redlamp?.values["basic.exposure"] == 0.7 else { throw CatalogError(message: "Manual slider recipe lost") }
        editor.tab = "crop"; try await wait { !editor.rendering }
        editor.displayCrop = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        editor.applyCrop(); try await wait { !editor.rendering }
        let crop = editor.parameters
        var config = try ColorRuntime.configuration()
        config["colorWorker"] = FileManager.default.currentDirectoryPath + "/Tests/color_worker_fixture.py"
        let configURL = directory.appendingPathComponent("config.json")
        try JSONEncoder().encode(config).write(to: configURL)
        setenv("PHOTOLAB_AI_CONFIG", configURL.path, 1)
        editor.colorPrompt = "fixture"
        editor.startAI(); try await wait { !editor.aiRunning && !editor.rendering }
        guard editor.aiError == nil, editor.parameters.redlamp?.values["basic.exposure"] == 0.3,
              editor.parameters.cropX == crop.cropX, editor.parameters.cropWidth == crop.cropWidth,
              editor.englishPrompt == "fixture English" else { throw CatalogError(message: "AI application did not replace color and preserve crop: \(editor.aiError ?? "")") }
        let colored = editor.parameters
        editor.undo(); guard editor.parameters == crop else { throw CatalogError(message: "AI undo lost previous grade") }
        editor.redo(); guard editor.parameters == colored else { throw CatalogError(message: "AI redo failed") }
        editor.colorPrompt = "fail"; editor.startAI(); try await wait { !editor.aiRunning }
        guard editor.aiError != nil, editor.parameters == colored else { throw CatalogError(message: "Failed AI changed parameters") }
        editor.colorPrompt = "slow"; editor.startAI()
        try await Task.sleep(for: .milliseconds(800)); editor.cancelAI()
        try await Task.sleep(for: .milliseconds(800))
        guard !editor.aiRunning, editor.parameters == colored else { throw CatalogError(message: "Cancelled AI changed parameters") }
        editor.complete(); try await wait { !editor.isPresented }
        guard let saved = try PhotoEditStore.read(source), saved.document.pipelineVersion == 3,
              saved.document.adjustments == colored, saved.document.tiffBytes > 0 else { throw CatalogError(message: "AI grade/crop/cache not persisted") }
        editor.open(items, selectedID: "color"); try await wait { editor.canEdit && !editor.rendering && editor.image != nil }
        guard editor.tab == "ai", editor.parameters == colored else { throw CatalogError(message: "Reopen lost AI parameters") }
        editor.switchToRedlamp()
        guard editor.parameters.cropWidth == colored.cropWidth, editor.parameters.redlamp == .neutral else { throw CatalogError(message: "Color reset changed crop") }
        editor.resetAdjustments(); editor.complete(); try await wait { !editor.isPresented }
        guard try PhotoEditStore.read(source) == nil else { throw CatalogError(message: "Full reset retained sidecar") }
        print("PASS editor AI default, manual undo, crop retention, AI replacement/undo/redo/failure/cancel, save/reopen/reset (fixture inference + real Redlamp)")
    }
}
