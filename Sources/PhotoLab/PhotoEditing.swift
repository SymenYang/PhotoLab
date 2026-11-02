import SwiftUI
import AppKit
import CoreImage
import Translation

struct EditablePhoto: Identifiable {
    var id: String
    var name: String
    var sources: [URL]
    var rotation: Int
}
actor PhotoEditSession {
    let source: URL
    private var envelope: EditEnvelope?
    private var document: PhotoEditDocument?
    private var previewEngine: NativeColorEngine?
    private var previewIdentity: EditSource?
    init(source: URL) { self.source = source }
    func load() throws -> (PhotoAdjustments, Bool, PhotoAdjustments, Int) {
        envelope = try PhotoEditStore.read(source)
        if let envelope {
            guard try PhotoEditStore.sourceMatches(source, document: envelope.document) else { throw CatalogError(message: "原片与编辑文件记录不匹配，未加载旧参数。请核对原片或恢复备份。") }
            document = envelope.document
        } else {
            document = PhotoEditDocument(source: try EditSource.read(source))
            document?.pipelineVersion = 3
            document?.adjustments.redlamp = .neutral
        }
        var defaults = envelope != nil && document?.adjustments.redlamp == nil ? try PhotoEditStore.sourceDefaults(source) : PhotoAdjustments()
        defaults.redlamp = .neutral
        var settings = document!.adjustments
        if settings.asShot { settings.temperature = defaults.temperature; settings.tint = defaults.tint }
        return (settings, envelope != nil, defaults, document!.pipelineVersion)
    }
    func render(_ adjustments: PhotoAdjustments, rotation: Int = 0, pipelineVersion: Int = 2, previewLongEdge: Int = 2048) throws -> NSImage {
        try Task.checkCancellation()
        return try autoreleasepool {
            let logicalSize: CGSize
            var rendered: CIImage
            if let grade = adjustments.redlamp {
                let identity = try EditSource.read(source)
                let desiredEdge = max(2048, min(32768, Int(ceil(Double(previewLongEdge) / max(0.01, min(adjustments.cropWidth, adjustments.cropHeight))))))
                let needsLargerBase = Scanner.rawExtensions.contains(source.pathExtension.lowercased()) && previewEngine.map {
                    Double(desiredEdge) > max($0.size.width, $0.size.height) + 1 && max($0.size.width, $0.size.height) < max($0.sourceSize.width, $0.sourceSize.height)
                } == true
                if previewEngine == nil || previewIdentity != identity || needsLargerBase {
                    previewEngine = nil
                    previewEngine = try RedlampBackend.preparePreview(source, maxLongEdge: desiredEdge)
                    previewIdentity = identity
                }
                try Task.checkCancellation()
                var engine = previewEngine!
                // Budget source pixels for the visible crop, rather than enlarging
                // a crop taken from an already downsampled full-image preview.
                let outputSize = PhotoEditStore.geometry(CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: engine.sourceSize)), adjustments: adjustments).extent.size
                let sourceEdge = max(engine.sourceSize.width, engine.sourceSize.height)
                let outputEdge = max(1, max(outputSize.width, outputSize.height))
                let decodeEdge = Int(ceil(min(sourceEdge, Double(previewLongEdge) * sourceEdge / outputEdge)))
                if Scanner.rawExtensions.contains(source.pathExtension.lowercased()),
                   Double(decodeEdge) > max(engine.size.width, engine.size.height) + 1,
                   max(engine.size.width, engine.size.height) < sourceEdge {
                    previewEngine = nil
                    engine = try RedlampBackend.preparePreview(source, maxLongEdge: decodeEdge)
                    previewEngine = engine
                }
                try Task.checkCancellation()
                let pixels = try engine.render(grade, previewLongEdge: decodeEdge)
                let base = CIImage(cgImage: pixels).transformed(by: CGAffineTransform(scaleX: engine.sourceSize.width / Double(pixels.width), y: engine.sourceSize.height / Double(pixels.height)))
                let geometry = PhotoEditStore.geometry(base, adjustments: adjustments)
                logicalSize = geometry.extent.size
                let scale = min(1, Double(previewLongEdge) / max(logicalSize.width, logicalSize.height))
                rendered = geometry.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            } else {
                previewEngine = nil; previewIdentity = nil
                rendered = try PhotoEditStore.render(source, adjustments: adjustments, pipelineVersion: pipelineVersion)
                logicalSize = rendered.extent.size
                let scale = min(1, Double(previewLongEdge) / max(logicalSize.width, logicalSize.height))
                rendered = rendered.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
            if rotation != 0 { rendered = rendered.oriented(rotation == 1 ? .right : rotation == 2 ? .down : .left) }
            try Task.checkCancellation()
            let cg = try PhotoEditStore.cgImage(rendered)
            try Task.checkCancellation()
            let displayed = rotation % 2 == 0 ? logicalSize : CGSize(width: logicalSize.height, height: logicalSize.width)
            let bitmap = NSBitmapImageRep(cgImage: cg)
            bitmap.size = displayed
            let image = NSImage(size: displayed)
            image.addRepresentation(bitmap)
            return image
        }
    }
    func previewWhiteBalance() -> [String: Double] { previewEngine?.whiteBalance ?? [:] }
    func previewDiagnostics() -> (opens: Int, renders: Int) { (previewEngine?.opens ?? 0, previewEngine?.previews ?? 0) }
    @discardableResult func save(_ adjustments: PhotoAdjustments, cache: Bool, pipelineVersion: Int = 2) throws -> Bool {
        try Task.checkCancellation()
        guard var document else { throw CatalogError(message: "编辑尚未加载") }
        document.adjustments = adjustments; document.pipelineVersion = adjustments.redlamp == nil ? pipelineVersion : 3
        let saved = try autoreleasepool { try PhotoEditStore.commit(document, source: source, expectedToken: envelope?.token, cache: cache) }
        envelope = saved; self.document = saved?.document ?? document
        return saved != nil
    }
}

@MainActor final class PhotoEditorModel: ObservableObject {
    static let shared = PhotoEditorModel()
    let autoCrop = AutoCropModel()
    @Published var isPresented = false
    @Published private(set) var photos: [EditablePhoto] = []
    @Published private(set) var index = 0
    @Published private(set) var source: URL?
    @Published private(set) var image: NSImage?
    private var baseImage: NSImage?
    private var decorationTask: Task<Void, Never>?
    private var decorationGeneration = UUID()
    @Published var selectedStickerID: String?
    @Published private(set) var frameMetadata = FrameMetadata()
    var decoration: PhotoDecoration { parameters.decoration ?? PhotoDecoration() }
    func updateDecoration(_ change: (inout PhotoDecoration) -> Void) {
        var d = decoration; change(&d)
        do { try d.validate(); parameters.decoration = d; error = nil }
        catch { self.error = error.localizedDescription }
    }
    func addSticker(_ sticker: PhotoSticker) {
        updateDecoration { $0.stickers.append(sticker) }; selectedStickerID = sticker.id
    }
    var decorationPhotoSize: CGSize {
        let size = baseImage?.size ?? CGSize(width:1000,height:667)
        return (current?.rotation ?? 0)%2 == 0 ? size : CGSize(width:size.height,height:size.width)
    }
    var stickerFontPixelScale: Double {
        let canvas = DecorationLayout.make(photo: decorationPhotoSize, decoration: decoration).size
        return max(1,min(canvas.width,canvas.height))
    }
    func setStickerFontSize(_ id: String, pixels: Double) {
        guard pixels.isFinite else { return }
        let size = min(0.5,max(0.003,pixels/stickerFontPixelScale))
        updateDecoration { d in
            guard let i = d.stickers.firstIndex(where: { $0.id == id && $0.kind == "text" }) else { return }
            d.stickers[i].textSize = size
        }
    }
    func applyInformationPreset(_ template: String) {
        updateDecoration { $0.addInformationPreset(template, metadata: frameMetadata, photo: decorationPhotoSize) }
        selectedStickerID = decoration.stickers.first(where: { $0.templateSlot != nil })?.id
    }
    func applyDecorationPreset(_ value: PhotoDecoration) {
        parameters.decoration = value.migrated(metadata: frameMetadata, photo: decorationPhotoSize)
        selectedStickerID = nil
    }
    private func composePreview() {
        decorationTask?.cancel(); decorationGeneration = UUID()
        guard let baseImage, let cg = baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        if let old = parameters.decoration,
           case let converted = old.migrated(metadata: frameMetadata, photo: decorationPhotoSize), converted != old {
            let wasReady = ready; ready = false
            parameters.decoration = converted
            if lastSaved.decoration == old { lastSaved.decoration = converted }
            ready = wasReady
        }
        guard !showOriginal, cropDraft == nil, decoration.active else { image = baseImage; return }
        let d = decoration, metadata = frameMetadata, rotation = current?.rotation ?? 0
        let token = decorationGeneration, key = generation, logical = baseImage.size
        decorationTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(25))
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let composed = try PhotoDecorationRenderer.compose(CIImage(cgImage: cg), decoration: d, metadata: metadata, rotation: rotation)
                    try Task.checkCancellation()
                    let pixels = try PhotoEditStore.cgImage(composed)
                    try Task.checkCancellation()
                    return pixels
                }
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, token == decorationGeneration, key == generation else { return }
                let upright = rotation % 2 == 0 ? logical : CGSize(width: logical.height, height: logical.width)
                let framed = DecorationLayout.make(photo: upright, decoration: d).size
                let size = rotation % 2 == 0 ? framed : CGSize(width: framed.height, height: framed.width)
                let bitmap = NSBitmapImageRep(cgImage: result); bitmap.size = size
                let output = NSImage(size: size); output.addRepresentation(bitmap); image = output
            } catch { if !Task.isCancelled, key == generation { self.error = error.localizedDescription } }
        }
    }
    @Published private(set) var loading = false
    @Published private(set) var rendering = false
    @Published private(set) var saving = false
    @Published private(set) var finishing = false
    @Published private(set) var sourceDefaults = PhotoAdjustments()
    @Published var pipelineVersion = 2 { didSet {
        if ready && pipelineVersion != oldValue { autoCrop.clear(); render(); markDraftChanged() }
    } }
    private var lastSavedPipeline = 2
    var isRAW: Bool { source.map { Scanner.rawExtensions.contains($0.pathExtension.lowercased()) } ?? false }
    func setAsShot(_ enabled: Bool) {
        var p = parameters
        if enabled || p.asShot { p.temperature = sourceDefaults.temperature; p.tint = sourceDefaults.tint }
        p.asShot = enabled; parameters = p
    }
    func resetAdjustments() { parameters = sourceDefaults }
    @Published var colorPrompt = ""
    @Published private(set) var englishPrompt = ""
    @Published private(set) var aiRunning = false
    @Published private(set) var aiStatus = ""
    @Published private(set) var aiError: String?
    private var aiTask: Task<Void, Never>?
    private var aiGeneration = UUID()
    @Published private(set) var translationConfiguration: TranslationSession.Configuration?
    @Published private(set) var isTranslating = false
    private var translationSession: TranslationSession?
    private var translationRequest: (id: UUID, prompt: String)?
    var needsTranslation: Bool { ColorPrompt.containsChinese(colorPrompt) }
    func startTranslation() {
        let prompt = colorPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ready, !aiRunning, cropDraft == nil, needsTranslation, prompt.count <= 1000 else { return }
        aiGeneration = UUID()
        translationRequest = (aiGeneration, colorPrompt)
        aiRunning = true; isTranslating = true; aiError = nil; englishPrompt = ""
        aiStatus = "正在用 Apple 翻译…首次使用可能需要下载语言资源"
        translationConfiguration = .init(source: .init(identifier: "zh-Hans"), target: .init(identifier: "en"))
    }
    func translate(using session: TranslationSession) async {
        guard let request = translationRequest else { return }
        translationSession = session
        await finishTranslation(id: request.id, prompt: request.prompt) {
            try await session.prepareTranslation()
            return try await session.translate(request.prompt).targetText
        }
    }
    func finishTranslation(id: UUID? = nil, prompt: String, operation: () async throws -> String) async {
        let job = id ?? aiGeneration
        guard isTranslating, job == aiGeneration else { return }
        do {
            let translated = try await operation().trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            guard job == aiGeneration else { return }
            guard colorPrompt == prompt else { throw CatalogError(message: "输入已变化，未覆盖当前文字。") }
            guard !translated.isEmpty else { throw CatalogError(message: "Apple 翻译返回空结果，请重试。") }
            colorPrompt = translated
            aiStatus = "翻译完成，请检查英文（尤其是人名和约束），再点击开始生成并应用调色。"
        } catch {
            guard job == aiGeneration else { return }
            if !Task.isCancelled { aiError = error.localizedDescription }
            aiStatus = "翻译未完成，原输入和调整保持不变"
        }
        guard job == aiGeneration else { return }
        translationRequest = nil; translationSession = nil; translationConfiguration = nil
        aiRunning = false; isTranslating = false
    }
    func cancelAI() {
        translationSession?.cancel(); translationSession = nil
        translationRequest = nil; translationConfiguration = nil; isTranslating = false
        aiTask?.cancel(); aiTask = nil; aiGeneration = UUID(); aiRunning = false
        aiStatus = "已取消，原调整保持不变"
    }
    func startAI() {
        let prompt = colorPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ready, !aiRunning, !needsTranslation, cropDraft == nil, let source, !prompt.isEmpty, prompt.count <= 1000 else { return }
        let original = parameters, key = generation, job = UUID()
        aiGeneration = job; aiRunning = true; aiError = nil; englishPrompt = ""; aiStatus = "等待本地推理资源…"
        aiTask = Task { [self] in
            do {
                let identity = try EditSource.read(source)
                let control = WorkControl(priority: 2)
                try await WorkScheduler.shared.acquire(.inference, control: control, minimumPriority: 4)
                await ModelService.embeddings.releaseIdleForColor()
                await ModelService.scores.releaseIdleForColor()
                let worker = Task.detached(priority: .userInitiated) {
                    try RedlampBackend.generate(source, prompt: prompt) { message, english in
                        Task { @MainActor [weak self] in
                            guard let self, self.aiGeneration == job else { return }
                            self.aiStatus = message; self.englishPrompt = english
                        }
                    }
                }
                let grade: RedlampGrade
                do {
                    grade = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    await WorkScheduler.shared.release(.inference)
                } catch {
                    await WorkScheduler.shared.release(.inference)
                    throw error
                }
                try Task.checkCancellation()
                guard key == generation, job == aiGeneration, parameters == original,
                      try EditSource.read(source) == identity else { throw CatalogError(message: "图片或调整已变化，未覆盖当前编辑。请重试。") }
                var updated = colorResetPreservingCrop()
                updated.redlamp = grade
                parameters = updated
                aiRunning = false; englishPrompt = grade.englishPrompt ?? prompt
                aiStatus = "已应用 · 可到手动调色继续调整，或撤销"
            } catch {
                guard key == generation, job == aiGeneration else { return }
                aiRunning = false
                if !Task.isCancelled { aiError = error.localizedDescription; aiStatus = "未应用，原调整保持不变" }
            }
        }
    }
    private func colorResetPreservingCrop() -> PhotoAdjustments {
        var updated = sourceDefaults
        updated.decoration = parameters.decoration
        updated.quarterTurns = parameters.quarterTurns; updated.straighten = parameters.straighten
        updated.cropX = parameters.cropX; updated.cropY = parameters.cropY
        updated.cropWidth = parameters.cropWidth; updated.cropHeight = parameters.cropHeight
        return updated
    }
    func switchToRedlamp() { parameters = colorResetPreservingCrop() }
    @Published private(set) var renderedColorWhiteBalance: [String: Double] = [:]
    func colorWhiteBalanceValue(_ key: String) -> Double {
        let fallback = key == "wb.temperature" ? 5500.0 : 0.0
        guard let grade = parameters.redlamp else { return fallback }
        if grade.whiteBalance == "custom" { return grade.values[key] ?? fallback }
        if grade.whiteBalance == "asShot" { return fallback }
        return renderedColorWhiteBalance[key] ?? fallback
    }
    private func preserveRenderedWhiteBalance(_ grade: inout RedlampGrade) throws {
        guard grade.whiteBalance != "custom" else { return }
        try grade.set("wb.temperature", value: colorWhiteBalanceValue("wb.temperature"))
        try grade.set("wb.tint", value: colorWhiteBalanceValue("wb.tint"))
    }
    func setColor(_ key: String, value: Double) {
        guard !aiRunning, var grade = parameters.redlamp else { return }
        do {
            if key == "wb.temperature" || key == "wb.tint" { try preserveRenderedWhiteBalance(&grade) }
            try grade.set(key, value: value); parameters.redlamp = grade
        }
        catch { self.error = error.localizedDescription }
    }
    func setColorField(_ key: String, value: Any) {
        guard !aiRunning, var grade = parameters.redlamp else { return }
        do {
            if key == "whiteBalance", value as? String == "custom" { try preserveRenderedWhiteBalance(&grade) }
            try grade.setField(key, value: value); parameters.redlamp = grade
        }
        catch { self.error = error.localizedDescription }
    }
    func setColorCurve(_ key: String, points: [GradeCurvePoint]) {
        guard !aiRunning, var grade = parameters.redlamp else { return }
        do { try grade.setCurve(key, points: points); parameters.redlamp = grade }
        catch { self.error = error.localizedDescription }
    }
    @Published var error: String?
    @Published var status = ""
    @Published var tab = "ai" { didSet {
        if tab == "crop" && cropDraft == nil && ready { beginCrop() }
        else if tab != "crop" && cropDraft != nil { cropDraft = nil; rotatingCrop = false; render() }
    } }
    @Published var cropDraft: PhotoAdjustments? { didSet {
        if cropDraft?.straighten != oldValue?.straighten || cropDraft?.quarterTurns != oldValue?.quarterTurns || (cropDraft == nil) != (oldValue == nil) { autoCrop.clear() }
        else if cropDraft != oldValue { autoCrop.cropChanged() }
    } }
    @Published var cropRatio = "自由" { didSet { if cropRatio != oldValue { autoCrop.clear() } } }
    @Published var customRatioWidth = 3.0 { didSet { if customRatioWidth != oldValue { autoCrop.clear() } } }
    @Published var customRatioHeight = 2.0 { didSet { if customRatioHeight != oldValue { autoCrop.clear() } } }
    @Published var cropPortrait = false { didSet { if cropPortrait != oldValue { autoCrop.clear() } } }
    @Published var rotatingCrop = false
    var cropAspect: Double? {
        let ratio: Double
        switch cropRatio {
        case "原图": guard image != nil else { return nil }; ratio = cropCanvasSize.width / cropCanvasSize.height
        case "1:1": ratio = 1
        case "3:2": ratio = 1.5
        case "4:3": ratio = 4.0 / 3
        case "3:4": ratio = 3.0 / 4
        case "2:3": ratio = 2.0 / 3
        case "9:16": ratio = 9.0 / 16
        case "16:9": ratio = 16.0 / 9
        case "自定义": ratio = customRatioWidth / max(0.1, customRatioHeight)
        default: return nil
        }
        return cropPortrait ? 1 / ratio : ratio
    }
    var cropCanvasSize: CGSize {
        guard let image else { return .zero }
        return PhotoEditStore.rotationBounds(image.size, degrees: cropDraft?.straighten ?? 0).size
    }
    var displayCrop: CGRect {
        get {
            let a = cropDraft ?? parameters
            return CropGeometry.rotated(CGRect(x: a.cropX, y: 1-a.cropY-a.cropHeight, width: a.cropWidth, height: a.cropHeight), turns: current?.rotation ?? 0)
        }
        set {
            guard var a = cropDraft else { return }
            let rect = CropGeometry.rotated(newValue, turns: (4-(current?.rotation ?? 0)) % 4)
            a.cropX = rect.minX; a.cropY = max(0, 1-rect.maxY); a.cropWidth = rect.width; a.cropHeight = rect.height
            cropDraft = a
        }
    }
    func beginCrop() {
        guard ready else { return }
        cropDraft = parameters; cropRatio = "自由"; cropPortrait = false; showOriginal = false; render()
    }
    func cancelCrop() { cropDraft = nil; rotatingCrop = false; tab = "ai"; render() }
    func applyCrop() {
        guard !rendering, let draft = cropDraft else { return }
        cropDraft = nil; rotatingCrop = false; tab = "ai"; parameters = draft; render()
    }
    func fitCropRatio() {
        guard let aspect = cropAspect, image != nil else { return }
        displayCrop = CropGeometry.fitted(displayCrop, ratio: aspect * cropCanvasSize.height / cropCanvasSize.width)
    }
    func rotateCrop(_ key: WritableKeyPath<PhotoAdjustments, Double>, value: Double) {
        cropDraft?[keyPath: key] = value; fitCropRatio()
    }
    func turnCrop(_ delta: Int) {
        guard var draft = cropDraft else { return }
        draft.quarterTurns = (draft.quarterTurns + delta + 4) % 4
        draft.cropX = 0; draft.cropY = 0; draft.cropWidth = 1; draft.cropHeight = 1
        cropDraft = draft; render()
    }
    func resetCrop() { displayCrop = CGRect(x: 0, y: 0, width: 1, height: 1); cropRatio = "自由" }
    @Published var showOriginal = false { didSet { render() } }
    @Published var parameters = PhotoAdjustments() {
        didSet {
            guard ready, parameters != oldValue else { return }
            if !aiRunning { englishPrompt = parameters.redlamp?.englishPrompt ?? "" }
            if !restoring && dragStart == nil { undoValues.append(oldValue); if undoValues.count > 100 { undoValues.removeFirst() }; redoValues = [] }
            if parameters.photoOnly != oldValue.photoOnly { autoCrop.clear(); render() } else { composePreview() }
            markDraftChanged()
        }
    }
    @Published private(set) var undoValues: [PhotoAdjustments] = []
    @Published private(set) var redoValues: [PhotoAdjustments] = []
    private var dragStart: PhotoAdjustments?
    private var restoring = false
    private var ready = false
    private var exists = false
    private var lastSaved = PhotoAdjustments()
    private var session: PhotoEditSession?
    private var generation = UUID()
    private var loadTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private struct PreviewRequest {
        let settings: PhotoAdjustments
        let rotation: Int
        let pipeline: Int
        let edge: Int
        let cropping: Bool
    }
    private var pendingPreview: PreviewRequest?
    private var previewRun = UUID()
    private var previewDisplayEdge = 2048
    @Published private(set) var previewPixels = CGSize.zero
    @Published private(set) var previewMilliseconds = 0.0
    var onCommit: ((String) -> Void)?
    var onBatchChange: ((Set<String>) -> Void)?
    private var decorationBatchIDs: Set<String> = []
    var decorationTargets: [EditablePhoto] { photos.filter { decorationBatchIDs.contains($0.id) } }
    var onSelect: ((String) -> Void)?
    var current: EditablePhoto? { photos.indices.contains(index) ? photos[index] : nil }
    var canEdit: Bool { ready && baseImage != nil }
    var unsaved: Bool { ready && (parameters != lastSaved || pipelineVersion != lastSavedPipeline || (cropDraft != nil && cropDraft != parameters)) }
    func open(_ photos: [EditablePhoto], selectedID: String, batchIDs: Set<String> = []) {
        guard !isPresented, !photos.isEmpty else { return }
        decorationBatchIDs = batchIDs.isEmpty ? [selectedID] : batchIDs
        self.photos = photos; index = photos.firstIndex { $0.id == selectedID } ?? 0
        isPresented = true; load()
    }
    private func load(source explicit: URL? = nil) {
        guard let current else { return }
        cancelAI(); colorPrompt = ""; englishPrompt = ""; aiError = nil; aiStatus = ""
        loadTask?.cancel(); stopPreview(); generation = UUID()
        let key = generation
        ready = false; cropDraft = nil; tab = "ai"; loading = true; rendering = false; saving = false; error = nil; image = nil; undoValues = []; redoValues = []; dragStart = nil; showOriginal = false
        source = nil; session = nil; renderedColorWhiteBalance = [:]; baseImage = nil; selectedStickerID = nil
        decorationTask?.cancel(); frameMetadata = FrameMetadata()
        status = "正在检查编辑记录…"
        loadTask = Task {
            do {
                let discovered = explicit == nil ? try await PhotoEditStore.findPreferredSource(current.sources) : nil
                guard !Task.isCancelled, key == generation else { return }
                let preferred = explicit ?? discovered ?? current.sources.first(where: { Scanner.rawExtensions.contains($0.pathExtension.lowercased()) }) ?? current.sources[0]
                let metadata = await Task.detached { FrameMetadata.read(preferred) }.value
                guard !Task.isCancelled, key == generation else { return }
                frameMetadata = metadata
                source = preferred
                let session = PhotoEditSession(source: preferred); self.session = session
                status = "正在准备编辑预览…"
                let (settings, exists, defaults, pipeline) = try await session.load()
                guard !Task.isCancelled, key == generation else { return }
                sourceDefaults = defaults; pipelineVersion = pipeline; lastSavedPipeline = pipeline; parameters = settings; lastSaved = settings; self.exists = exists; ready = true; loading = false
                colorPrompt = settings.redlamp?.originalPrompt ?? ""; englishPrompt = settings.redlamp?.englishPrompt ?? ""
                status = exists ? "已加载原片旁的编辑文件" : "尚未编辑 · 原文件保持不变"
                onSelect?(current.id); render()
            } catch { if !Task.isCancelled, key == generation { loading = false; self.error = error.localizedDescription } }
        }
    }
    func updatePreviewSize(_ edge: Int) {
        let clamped = max(512, min(32768, ((edge + 127) / 128) * 128))
        guard clamped != previewDisplayEdge else { return }
        previewDisplayEdge = clamped; render()
    }
    private func stopPreview() {
        previewRun = UUID(); renderTask?.cancel(); renderTask = nil; pendingPreview = nil
    }
    private func render() {
        guard ready, let session else { return }
        var settings = showOriginal ? sourceDefaults : (cropDraft ?? parameters)
        settings.decoration = nil
        let pipeline = pipelineVersion
        let cropping = cropDraft != nil, rotation = cropping ? (current?.rotation ?? 0) : 0, key = generation
        if cropping { settings.straighten = 0; settings.cropX = 0; settings.cropY = 0; settings.cropWidth = 1; settings.cropHeight = 1 }
        let edge = dragStart != nil ? min(previewDisplayEdge, 1536) : previewDisplayEdge
        pendingPreview = PreviewRequest(settings: settings, rotation: rotation, pipeline: pipeline, edge: edge, cropping: cropping)
        rendering = true
        guard renderTask == nil else { return }
        let run = UUID(); previewRun = run
        renderTask = Task {
            while !Task.isCancelled, key == generation, run == previewRun, let request = pendingPreview {
                pendingPreview = nil
                do {
                    let started = Date()
                    let result = try await session.render(request.settings, rotation: request.rotation, pipelineVersion: request.pipeline, previewLongEdge: request.edge)
                    try Task.checkCancellation()
                    let balance = await session.previewWhiteBalance()
                    guard !Task.isCancelled, key == generation, run == previewRun else { return }
                    renderedColorWhiteBalance = balance
                    baseImage = result; composePreview()
                    previewPixels = result.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? .zero
                    previewMilliseconds = Date().timeIntervalSince(started) * 1000
                    if request.cropping && cropDraft != nil { fitCropRatio() }
                } catch {
                    guard !Task.isCancelled, key == generation, run == previewRun else { return }
                    self.error = error.localizedDescription
                }
            }
            if key == generation && run == previewRun { rendering = false; renderTask = nil }
        }
    }
    private func markDraftChanged() {
        // A draft never changes the sidecar or invalidates library analysis.
        status = unsaved ? "有未保存的修改 · 点击完成保存，关闭则放弃本次修改" : "与打开时一致 · 无需保存"
    }
    func sliderEditing(_ active: Bool) {
        if active { dragStart = parameters }
        else {
            if let start = dragStart, start != parameters { undoValues.append(start); redoValues = [] }
            let changedPhoto = dragStart.map { $0.photoOnly != parameters.photoOnly } ?? false
            dragStart = nil
            if changedPhoto { render() }
        }
    }
    func undo() {
        guard cropDraft == nil, let value = undoValues.popLast() else { return }
        redoValues.append(parameters); restoring = true; parameters = value; restoring = false
    }
    func redo() {
        guard cropDraft == nil, let value = redoValues.popLast() else { return }
        undoValues.append(parameters); restoring = true; parameters = value; restoring = false
    }
    func complete(next: Int? = nil, source: URL? = nil) {
        guard !finishing, !loading, cropDraft == nil || !rendering else { return }
        if let next, !photos.indices.contains(next) { return }
        if let source, current?.sources.contains(source) != true { return }
        cancelAI()
        if cropDraft != nil { applyCrop() }
        if !ready { if next == nil && source == nil { close() }; return }
        guard let session, let photoID = current?.id else { return }
        stopPreview(); finishing = true; saving = true; status = "正在保存编辑结果…"
        let settings = parameters, pipeline = pipelineVersion
        let shouldSave = unsaved && (exists || parameters.hasEffectiveChanges)
        Task {
            do {
                if shouldSave { let retained = try await session.save(settings, cache: true, pipelineVersion: pipeline); lastSaved = settings; lastSavedPipeline = pipeline; exists = retained; onCommit?(photoID) }
                finishing = false; saving = false; error = nil
                if let next { index = next; load() }
                else if let source { load(source: source) }
                else { close() }
            } catch { finishing = false; saving = false; self.error = error.localizedDescription; status = "未完成保存，当前调整仍保留在编辑器中"; render() }
        }
    }
    func discardAndSwitch(next: Int? = nil, source: URL? = nil) {
        guard !finishing, !loading else { return }
        if let next, photos.indices.contains(next) { index = next; load() }
        else if let source, current?.sources.contains(source) == true { load(source: source) }
    }
    func reload() { guard !finishing && !saving else { return }; load(source: source) }
    func close() {
        guard !finishing else { return }
        cancelAI()
        autoCrop.clear()
        loadTask?.cancel(); stopPreview(); generation = UUID(); ready = false
        cropDraft = nil; tab = "ai"; image = nil; baseImage = nil; decorationTask?.cancel(); decorationTask = nil; decorationGeneration = UUID(); session = nil; isPresented = false
        parameters = lastSaved; pipelineVersion = lastSavedPipeline; undoValues = []; redoValues = []; dragStart = nil
        loading = false; rendering = false; saving = false
    }
}

struct PhotoEditorView: View {
    @ObservedObject var editor: PhotoEditorModel
    @State private var zoom = 1.0
    @State private var reset = 0
    @State private var confirmClose = false
    @State private var confirmReload = false
    @State private var confirmSwitch = false
    @State private var nextPhoto: Int?
    @State private var nextSource: URL?
    var inspectorOnly = false
    var body: some View {
        Group {
            if inspectorOnly { inspector }
            else { VStack(spacing: 0) { header; Divider(); canvas } }
        }
        .tint(Color(red: 0.71, green: 0.86, blue: 0.54))
        .disabled(editor.finishing)
        .onChange(of: editor.source) { _, _ in zoom = 1; reset += 1 }
        .alert("放弃尚未保存的调整？", isPresented: $confirmClose) {
            Button("继续编辑", role: .cancel) {}
            Button("放弃本次修改并关闭", role: .destructive) { editor.close() }
        } message: { Text("将放弃本次打开编辑器后的全部修改，保留此前已保存的编辑结果。") }
        .alert("切换前保存本次修改？", isPresented: $confirmSwitch) {
            Button("保存并切换") { editor.complete(next: nextPhoto, source: nextSource) }
            Button("放弃修改并切换", role: .destructive) { editor.discardAndSwitch(next: nextPhoto, source: nextSource) }
            Button("继续编辑", role: .cancel) {}
        } message: { Text("保存后会更新照片的分析结果；放弃修改会保留此前已保存的版本。") }
        .alert("重新读取磁盘上的编辑文件？", isPresented: $confirmReload) {
            Button("取消", role: .cancel) {}
            Button("重新读取", role: .destructive) { editor.reload() }
        } message: { Text("将放弃当前尚未保存的调整，不覆盖磁盘上的编辑文件。") }
    }
    private func requestSwitch(next: Int? = nil, source: URL? = nil) {
        nextPhoto = next; nextSource = source
        if editor.unsaved { confirmSwitch = true }
        else { editor.discardAndSwitch(next: next, source: source) }
    }
    private var header: some View {
            HStack {
                Text(editor.current?.name ?? "照片编辑").font(.headline).lineLimit(1)
                Spacer()
                Button("上一张") { requestSwitch(next: editor.index - 1) }.disabled(editor.index == 0 || editor.loading || (editor.cropDraft != nil && editor.rendering))
                Button("下一张") { requestSwitch(next: editor.index + 1) }.disabled(editor.index + 1 >= editor.photos.count || editor.loading || (editor.cropDraft != nil && editor.rendering))
                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("进入 / 退出全屏").accessibilityLabel("编辑全屏")
                Button("关闭") { if editor.unsaved { confirmClose = true } else { editor.close() } }.disabled(editor.saving)
                Button(editor.finishing ? "正在保存…" : "完成") { editor.complete() }.buttonStyle(.borderedProminent).disabled(editor.loading || (editor.cropDraft != nil && editor.rendering))
            }.padding(14)
    }
    private var canvas: some View {
                VStack(spacing: 0) {
                    GeometryReader { geometry in
                        ZStack {
                            Color.black
                            if let image = editor.image {
                                if editor.cropDraft != nil {
                                    PhotoCropCanvas(image: image, angle: editor.cropDraft?.straighten ?? 0, zoom: $zoom, rect: Binding(get: { editor.displayCrop }, set: { editor.displayCrop = $0 }), aspect: editor.cropAspect, denseGrid: editor.rotatingCrop, onPreviewSize: editor.updatePreviewSize).disabled(editor.rendering)
                                } else if editor.tab == "decorate" && !editor.showOriginal {
                                    PhotoDecorationCanvas(editor: editor, image: image)
                                } else {
                                    ZoomImage(image: image, zoom: zoom, hdr: false, resetID: reset, rotation: editor.current?.rotation ?? 0, preserveViewport: true, onPreviewSize: editor.updatePreviewSize)
                                }
                            } else if editor.loading || editor.rendering { ProgressView("读取全分辨率原片…") }
                            else { Text(editor.error ?? "无法读取图片").foregroundStyle(.secondary).padding() }
                            if editor.rendering && editor.image != nil { VStack { HStack { Spacer(); ProgressView().controlSize(.small).padding() }; Spacer() } }
                        }
                        .overlay(alignment: .bottomLeading) {
                            HStack {
                                if editor.tab != "decorate" {
                                Button("适合窗口") { zoom = 1; reset += 1 }
                                Button("100%") {
                                    guard let image = editor.image else { return }
                                    let cropping = editor.cropDraft != nil
                                    let odd = !cropping && (editor.current?.rotation ?? 0) % 2 == 1
                                    let size = cropping ? editor.cropCanvasSize : image.size
                                    let width = odd ? size.height : size.width, height = odd ? size.width : size.height
                                    let fit = min((geometry.size.width - (cropping ? 32 : 0)) / width, (geometry.size.height - (cropping ? 90 : 0)) / height)
                                    zoom = max(1, 1 / max(0.0001, fit) / (NSScreen.main?.backingScaleFactor ?? 1)); reset += 1
                                }
                                if editor.cropDraft != nil {
                                    Button { zoom = max(1, zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }.accessibilityLabel("缩小裁剪画面")
                                    Button { zoom = min(32, zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }.accessibilityLabel("放大裁剪画面")
                                }
                                }
                                Toggle("查看原图", isOn: $editor.showOriginal).toggleStyle(.button).disabled(editor.cropDraft != nil)
                                if let image = editor.image { Text("\(Int(image.size.width)) × \(Int(image.size.height))").font(.caption.monospacedDigit()) }
                            }.padding(10).background(.black.opacity(0.7))
                        }
                    }
                    .onGeometryChange(for: Int.self) { proxy in Int(max(proxy.size.width, proxy.size.height) * (NSScreen.main?.backingScaleFactor ?? 2)) } action: { editor.updatePreviewSize($0) }
                    HStack {
                        Text(editor.status).lineLimit(2).font(.caption); Spacer()
                        if editor.parameters.redlamp != nil && editor.previewPixels.width > 0 {
                            Text("预览 \(Int(editor.previewPixels.width))×\(Int(editor.previewPixels.height)) · \(Int(editor.previewMilliseconds))ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if editor.saving { ProgressView().controlSize(.small) }
                    }.padding(10)
                }
    }
    private var inspector: some View {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let current = editor.current {
                            Picker("编辑输入", selection: Binding(get: { editor.source?.path ?? "" }, set: { requestSwitch(source: URL(fileURLWithPath: $0)) })) {
                                ForEach(current.sources, id: \.path) { url in Text(url.lastPathComponent).tag(url.path) }
                            }.disabled(editor.loading || editor.saving || (editor.cropDraft != nil && editor.rendering))
                        }
                        Text("RAW 与直出分别保存编辑记录；有未保存修改时，切换输入会询问是否保存。").font(.caption).foregroundStyle(.secondary)
                        Picker("工具", selection: $editor.tab) { Text("AI 调色").tag("ai"); Text("手动调色").tag("manual"); Text("裁切").tag("crop"); Text("边框贴纸").tag("decorate") }.pickerStyle(.segmented).controlSize(.small).labelsHidden().disabled(editor.aiRunning)
                        Group {
                        if editor.tab == "ai" {
                            aiPanel
                        } else if editor.tab == "manual" {
                            manualPanel
                        } else if editor.tab == "decorate" {
                            PhotoDecorationPanel(editor: editor)
                        } else {
                            Text("拖动边角裁剪，框内拖动移动选区。捏合缩放，双指滚动平移画面。").font(.caption).foregroundStyle(.secondary)
                            Picker("比例", selection: $editor.cropRatio) {
                                ForEach(["自由", "原图", "1:1", "3:2", "2:3", "4:3", "3:4", "16:9", "9:16", "自定义"], id: \.self) { Text($0) }
                            }.onChange(of: editor.cropRatio) { _, _ in editor.cropPortrait = false; editor.fitCropRatio() }
                            if editor.cropRatio == "自定义" {
                                PhotoAdjustmentControl(title: "比例宽", value: $editor.customRatioWidth, range: 0.1...100, step: 0.1, sliderEditing: { _ in editor.fitCropRatio() })
                                    .onChange(of: editor.customRatioWidth) { _, _ in editor.fitCropRatio() }
                                PhotoAdjustmentControl(title: "比例高", value: $editor.customRatioHeight, range: 0.1...100, step: 0.1, sliderEditing: { _ in editor.fitCropRatio() })
                                    .onChange(of: editor.customRatioHeight) { _, _ in editor.fitCropRatio() }
                            }
                            Button("横竖切换") { let flipped = ["3:2":"2:3", "2:3":"3:2", "4:3":"3:4", "3:4":"4:3", "16:9":"9:16", "9:16":"16:9"]
                                if let ratio = flipped[editor.cropRatio] { editor.cropPortrait = false; editor.cropRatio = ratio }
                                else if editor.cropRatio == "自定义" { let width = editor.customRatioWidth; editor.customRatioWidth = editor.customRatioHeight; editor.customRatioHeight = width }
                                else { editor.cropPortrait.toggle() }; editor.fitCropRatio() }.disabled(editor.cropAspect == nil)
                            HStack {
                                Button("左转 90°") { editor.turnCrop(-1) }
                                Button("右转 90°") { editor.turnCrop(1) }
                            }
                            PhotoAdjustmentControl(title: "旋转 °", value: Binding(get: { editor.cropDraft?.straighten ?? 0 }, set: { editor.rotateCrop(\.straighten, value: $0) }), range: -15...15, step: 0.1, sliderEditing: { editor.rotatingCrop = $0 })
                            Button("重置裁剪") { editor.resetCrop() }
                            HStack {
                                Button("取消") { editor.cancelCrop() }.keyboardShortcut(.escape, modifiers: [])
                                Button("应用裁剪") { editor.applyCrop() }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: []).disabled(editor.rendering)
                            }
                            Text("应用裁剪只更新编辑预览，点击完成才保存。切换模块会取消未应用的裁切。").font(.caption).foregroundStyle(.secondary)
                            AutoCropPanel(editor: editor, search: editor.autoCrop)

                        }
                        }.disabled(!editor.canEdit || editor.showOriginal)
                        HStack {
                            Button("撤销") { editor.undo() }.disabled(editor.undoValues.isEmpty || editor.cropDraft != nil)
                            Button("重做") { editor.redo() }.disabled(editor.redoValues.isEmpty || editor.cropDraft != nil)
                        }.disabled(editor.aiRunning)
                        Button("恢复原图") { editor.resetAdjustments() }.disabled(editor.cropDraft != nil || editor.aiRunning)
                        Text("点击完成后保存到原片旁，并更新分析结果；关闭则放弃本次修改。原片保持不变。当前输出为 SDR。").font(.caption).foregroundStyle(.secondary)
                        if let error = editor.error {
                            Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                            Button("重试保存") { editor.complete() }.disabled(editor.loading)
                            Button("重新读取编辑文件…") { confirmReload = true }.disabled(editor.saving)
                        }
                    }.padding(16)
                }
                .translationTask(editor.translationConfiguration) { session in
                    await editor.translate(using: session)
                }
    }
    private var aiPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("JarvisArt · 本地推理", systemImage: "sparkles").font(.headline)
            Text("描述你想要的色彩和氛围").font(.subheadline)
            TextEditor(text: $editor.colorPrompt).font(.body).frame(minHeight: 110, maxHeight: 180)
                .padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("AI 调色意图").disabled(editor.aiRunning)
            HStack {
                Button("森山大道风格") { editor.colorPrompt = "森山大道的风格，粗粝、高反差的黑白摄影" }
                Button("电影感") { editor.colorPrompt = "电影感，保留自然肤色，柔和高光，冷色阴影" }
            }.buttonStyle(.borderless).disabled(editor.aiRunning)
            Text("中文先用 Apple 系统翻译为英文，不替换专名或术语。检查并编辑英文后，再生成调色。翻译在设备上完成，首次可能需要下载语言资源；照片和文字不上传。每次重新生成会替换调色、保留裁切。").font(.caption).foregroundStyle(.secondary)
            if editor.isRAW { Text("RAW 按预览尺寸显影为 RGB 供模型分析；完成编辑或导出时再处理全尺寸原片。").font(.caption).foregroundStyle(.secondary) }
            if editor.parameters.redlamp == nil { Text("正在显示旧版编辑。生成成功后会替换旧调色，可撤销；不会叠加两套引擎。").font(.caption).foregroundStyle(.orange) }
            if editor.aiRunning {
                HStack { ProgressView().controlSize(.small); Button(editor.isTranslating ? "取消翻译" : "取消生成") { editor.cancelAI() } }
            } else {
                Button(editor.needsTranslation ? "翻译成英文" : "开始生成并应用调色") {
                    if editor.needsTranslation { editor.startTranslation() } else { editor.startAI() }
                }.buttonStyle(.borderedProminent)
                    .disabled(editor.colorPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editor.colorPrompt.count > 1000)
            }
            Text("本地模型约16GB，通常需要数分钟。手动调色不需要运行模型。").font(.caption).foregroundStyle(.secondary)
            if !editor.aiStatus.isEmpty { Text(editor.aiStatus).font(.caption) }
            if let error = editor.aiError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if !editor.englishPrompt.isEmpty {
                DisclosureGroup("实际英文输入") { Text(editor.englishPrompt).font(.caption).textSelection(.enabled) }
            }
            if let audit = editor.parameters.redlamp?.audit {
                DisclosureGroup("参数映射 / 未应用操作") { Text(audit).font(.caption.monospaced()).textSelection(.enabled) }
            }
            if let grade = editor.parameters.redlamp, !grade.isNeutral {
                DisclosureGroup("Redlamp 参数") {
                    Text(String(data: grade.settings, encoding: .utf8) ?? "").font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
    }
    private var manualPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Redlamp · 全局调色", systemImage: "slider.horizontal.3").font(.headline)
            if editor.parameters.redlamp == nil {
                Text("旧调色使用原引擎保留显示。开始使用 Redlamp 会重置旧调色并保留裁切，可撤销。").font(.caption).foregroundStyle(.secondary)
                Button("重置调色并启用 Redlamp") { editor.switchToRedlamp() }
            } else {
                colorControl("曝光 EV", "basic.exposure", -5...5, step: 0.05)
                ForEach([("对比度", "contrast"), ("高光", "highlights"), ("阴影", "shadows"), ("白色色阶", "whites"), ("黑色色阶", "blacks")], id: \.1) { item in
                    colorControl(item.0, "basic." + item.1)
                }
                DisclosureGroup("白平衡 / 颜色") {
                    VStack(spacing: 16) {
                        Picker("白平衡", selection: Binding(get: { editor.parameters.redlamp?.whiteBalance ?? "asShot" }, set: { editor.setColorField("whiteBalance", value: $0) })) {
                            Text("原始").tag("asShot")
                            Text("自动").tag("auto")
                            Text("自定义").tag("custom")
                        }.disabled(editor.rendering && editor.parameters.redlamp?.whiteBalance == "auto")
                        colorControls(ManualColorControl.whiteBalance)
                            .disabled(editor.rendering && editor.parameters.redlamp?.whiteBalance != "custom")
                        Text("色温越高越暖；色调从绿色偏向洋红。5500 K、色调 0 保持底图颜色。").font(.caption).foregroundStyle(.secondary)
                        colorControl("红色偏移", "wb.shift.red")
                        colorControl("蓝色偏移", "wb.shift.blue")
                        colorControl("自然饱和度", "basic.vibrance")
                        colorControl("饱和度", "basic.saturation")
                    }.padding(.top, 10)
                }
                DisclosureGroup("质感") {
                    VStack(spacing: 16) {
                        colorControl("纹理", "basic.texture"); colorControl("清晰度", "basic.clarity"); colorControl("去朦胧", "basic.dehaze")
                    }.padding(.top, 10)
                }
                Toggle("黑白", isOn: Binding(get: { editor.parameters.redlamp?.blackAndWhite ?? false }, set: { editor.setColorField("treatment", value: $0 ? "blackAndWhite" : "color") }))
                DisclosureGroup(editor.parameters.redlamp?.blackAndWhite == true ? "HSL / 黑白混色" : "HSL · 颜色混合器") {
                    VStack(spacing: 12) {
                        ForEach([("红", "red"), ("橙", "orange"), ("黄", "yellow"), ("绿", "green"), ("青", "aqua"), ("蓝", "blue"), ("紫", "purple"), ("洋红", "magenta")], id: \.1) { color in
                            DisclosureGroup(color.0) {
                                VStack(spacing: 16) {
                                    colorControl("色相", "mixer.hue." + color.1)
                                    colorControl("饱和度", "mixer.saturation." + color.1)
                                    colorControl("明亮度", "mixer.luminance." + color.1)
                                }.padding(.vertical, 10)
                            }
                        }
                    }.padding(.top, 10)
                }
                pointCurvePanel
                colorGroup("参数曲线", ManualColorControl.curveTone)
                gradingPanel
                colorGroup("锐化", ManualColorControl.sharpening)
                colorGroup("降噪", ManualColorControl.noise)
                colorGroup("暗角 · 高光优先", ManualColorControl.vignette)
                colorGroup("颗粒", ManualColorControl.grain)
                Text("可继续调整 AI 生成的参数和曲线，支持撤销、重做；点击完成后保存。").font(.caption).foregroundStyle(.secondary)
                Button("仅重置调色，保留裁切") { editor.switchToRedlamp() }
            }
        }.disabled(editor.aiRunning)
    }
    private var pointCurvePanel: some View {
        DisclosureGroup("点曲线 · RGB / 通道") {
            VStack(spacing: 12) {
                ForEach(Array(zip(["RGB 总曲线", "红通道", "绿通道", "蓝通道"], RedlampGrade.curveKeys)), id: \.1) { title, key in
                    DisclosureGroup(title) {
                        GradeCurveEditor(points: Binding(get: { editor.parameters.redlamp?.curve(key) ?? [] }, set: { editor.setColorCurve(key, points: $0) }), editing: editor.sliderEditing)
                            .padding(.top, 8)
                    }
                }
            }.padding(.top, 10)
        }
    }
    private var gradingPanel: some View {
        DisclosureGroup("色彩分级") {
            VStack(spacing: 16) {
                ForEach([("阴影", "shadows"), ("中间调", "midtones"), ("高光", "highlights"), ("全局", "global")], id: \.1) { title, band in
                    colorGroup(title, ManualColorControl.grading(band))
                }
                colorControls(ManualColorControl.gradingMix)
            }.padding(.top, 10)
        }
    }
    private func colorGroup(_ title: String, _ controls: [ManualColorControl]) -> some View {
        DisclosureGroup(title) { colorControls(controls).padding(.top, 10) }
    }
    private func colorControls(_ controls: [ManualColorControl]) -> some View {
        VStack(spacing: 16) {
            ForEach(controls) { control in
                colorControl(control.title, control.key, control.range, step: control.step, defaultValue: control.defaultValue)
            }
        }
    }
    private func colorControl(_ title: String, _ key: String, _ range: ClosedRange<Double> = -100...100, step: Double = 1, defaultValue: Double = 0) -> some View {
        PhotoAdjustmentControl(title: title, value: Binding(get: { (key == "wb.temperature" || key == "wb.tint") ? editor.colorWhiteBalanceValue(key) : (editor.parameters.redlamp?.values[key] ?? defaultValue) }, set: { editor.setColor(key, value: $0) }), range: range, step: step, sliderEditing: editor.sliderEditing, decimalPlaces: step < 1 ? 2 : 0)
    }
}

struct GradeCurveEditor: View {
    @Binding var points: [GradeCurvePoint]
    let editing: (Bool) -> Void
    @State private var selected = 0
    @State private var dragging = false
    private var validSelection: Bool { points.indices.contains(selected) }
    private func move(_ index: Int, x: Double, y: Double) {
        guard points.indices.contains(index) else { return }
        let lower = index == 0 ? 0 : points[index - 1].x + 0.0001
        let upper = index == points.count - 1 ? 1 : points[index + 1].x - 0.0001
        guard lower <= upper else { return }
        var updated = points
        updated[index] = GradeCurvePoint(x: min(upper, max(lower, x)), y: min(1, max(0, y)))
        points = updated
    }
    private func addPoint() {
        guard points.count >= 2, points.count < 256 else { return }
        let index = (0..<(points.count - 1)).max { points[$0 + 1].x - points[$0].x < points[$1 + 1].x - points[$1].x }!
        let left = points[index], right = points[index + 1]
        var updated = points
        updated.insert(.init(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2), at: index + 1)
        points = updated; selected = index + 1
    }
    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                let width = geometry.size.width, height = geometry.size.height
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.3))
                    Path { path in
                        for n in 1...3 {
                            let f = CGFloat(n) / 4
                            path.move(to: CGPoint(x: width * f, y: 0)); path.addLine(to: CGPoint(x: width * f, y: height))
                            path.move(to: CGPoint(x: 0, y: height * f)); path.addLine(to: CGPoint(x: width, y: height * f))
                        }
                        path.move(to: CGPoint(x: 0, y: height)); path.addLine(to: CGPoint(x: width, y: 0))
                    }.stroke(.secondary.opacity(0.3), lineWidth: 1)
                    Path { path in
                        for (index, point) in NativeColorEngine.curveSamples(points).enumerated() {
                            let position = CGPoint(x: point.x * width, y: (1 - point.y) * height)
                            if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
                        }
                    }.stroke(.primary, lineWidth: 1.5)
                    ForEach(points.indices, id: \.self) { index in
                        Circle().fill(index == selected ? Color.accentColor : .white)
                            .frame(width: 9, height: 9)
                            .position(x: points[index].x * width, y: (1 - points[index].y) * height)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    if !dragging {
                        selected = points.indices.min { a, b in
                            hypot(points[a].x * width - event.startLocation.x, (1 - points[a].y) * height - event.startLocation.y)
                                < hypot(points[b].x * width - event.startLocation.x, (1 - points[b].y) * height - event.startLocation.y)
                        } ?? 0
                        dragging = true; editing(true)
                    }
                    move(selected, x: event.location.x / max(1, width), y: 1 - event.location.y / max(1, height))
                }.onEnded { _ in dragging = false; editing(false) })
            }.frame(height: 180).accessibilityLabel("曲线控制点，下面可精确编辑输入和输出值")
            Text("拖动控制点，或输入精确值；横轴为输入，纵轴为输出。").font(.caption2).foregroundStyle(.secondary)
            Picker("控制点", selection: $selected) {
                ForEach(points.indices, id: \.self) { index in Text("点 \(index + 1)").tag(index) }
            }
            if validSelection {
                PhotoAdjustmentControl(title: "输入", value: Binding(get: { validSelection ? points[selected].x * 255 : 0 }, set: { if validSelection { move(selected, x: $0 / 255, y: points[selected].y) } }), range: 0...255, step: 1, sliderEditing: editing, decimalPlaces: 1)
                PhotoAdjustmentControl(title: "输出", value: Binding(get: { validSelection ? points[selected].y * 255 : 0 }, set: { if validSelection { move(selected, x: points[selected].x, y: $0 / 255) } }), range: 0...255, step: 1, sliderEditing: editing, decimalPlaces: 1)
            }
            HStack {
                Button("添加点", action: addPoint).disabled(points.count >= 256)
                Button("删除点") {
                    guard validSelection, points.count > 2 else { return }
                    var updated = points; updated.remove(at: selected)
                    selected = min(selected, updated.count - 1); points = updated
                }.disabled(points.count <= 2)
                Spacer()
                Button("重置通道") { selected = 0; points = [.init(x: 0, y: 0), .init(x: 1, y: 1)] }
            }.font(.caption)
        }
        .onChange(of: points.count) { _, count in selected = min(selected, max(0, count - 1)) }
        .onDisappear { if dragging { dragging = false; editing(false) } }
    }
}

struct PhotoAdjustmentControl: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let sliderEditing: (Bool) -> Void
    @State private var input = ""
    @FocusState private var focused: Bool
    var decimalPlaces: Int? = nil
    private var digits: Int { decimalPlaces ?? (step >= 100 ? 0 : 2) }
    private func formatted(_ number: Double) -> String { String(format: "%.*f", digits, number) }
    private func parsed() -> Double? { Double(input.replacingOccurrences(of: ",", with: ".")) }
    private func commit() {
        if input != formatted(value), let n = parsed(), n.isFinite { value = min(range.upperBound, max(range.lowerBound, n)) }
        input = formatted(value)
    }
    private func increment(_ direction: Double) {
        commit()
        value = min(range.upperBound, max(range.lowerBound, (value + step * direction).roundedToPrecision(digits)))
        input = formatted(value)
    }
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Text(title).font(.caption)
                Spacer(minLength: 4)
                Button { increment(-1) } label: { Image(systemName: "minus") }.disabled(value <= range.lowerBound)
                    .accessibilityLabel("减少" + title).help("减少 \(step.formatted())")
                TextField(title, text: $input).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    .monospacedDigit().frame(width: 72).focused($focused)
                    .accessibilityLabel(title + "精确值")
                    .onSubmit { commit() }
                    .onChange(of: focused) { _, active in if !active { commit() } }
                    .onChange(of: input) { _, _ in
                        if focused, let n = parsed(), n.isFinite { value = min(range.upperBound, max(range.lowerBound, n)) }
                    }
                Button { increment(1) } label: { Image(systemName: "plus") }.disabled(value >= range.upperBound)
                    .accessibilityLabel("增加" + title).help("增加 \(step.formatted())")
            }.buttonStyle(.borderless)
            if focused && (parsed().map { !$0.isFinite || !range.contains($0) } ?? true) {
                Text("请输入 \(formatted(range.lowerBound)) 至 \(formatted(range.upperBound))；超出范围按边界值处理").font(.caption2).foregroundStyle(.orange)
            }
            Slider(value: $value, in: range.lowerBound...max(range.lowerBound + 0.000001, range.upperBound), onEditingChanged: sliderEditing)
                .accessibilityLabel(title).disabled(range.upperBound <= range.lowerBound)
        }
        .onAppear { input = formatted(value) }
        .onChange(of: value) { _, _ in if !focused { input = formatted(value) } }
    }
}
private extension Double {
    func roundedToPrecision(_ digits: Int) -> Double {
        let factor = pow(10.0, Double(digits)); return (self * factor).rounded() / factor
    }
}

// Coordinates are normalized, with the origin at the displayed image's top-left.
enum CropGeometry {
    static func rotated(_ rect: CGRect, turns: Int) -> CGRect {
        var r = rect
        for _ in 0..<((turns % 4 + 4) % 4) { r = CGRect(x: 1-r.maxY, y: r.minX, width: r.height, height: r.width) }
        return r
    }
    static func fitted(_ rect: CGRect, ratio: Double) -> CGRect {
        let q = min(1_000_000, max(0.000001, ratio))
        var w = max(0.000001, sqrt(rect.width * rect.height * q)), h = max(0.000001, sqrt(rect.width * rect.height / q))
        w = max(w, h*q); h = w/q
        let scale = min(1, 2*min(rect.midX,1-rect.midX)/w, 2*min(rect.midY,1-rect.midY)/h); w *= scale; h *= scale
        return CGRect(x: max(0, rect.midX-w/2), y: max(0, rect.midY-h/2), width: w, height: h)
    }
    static func dragged(_ r: CGRect, handle: Int, delta: CGSize, ratio: Double?) -> CGRect {
        // -1 = move, 0...7 clockwise from top-left (corners and edge midpoints).
        if handle == -1 { return CGRect(x: min(1-r.width, max(0, r.minX+delta.width)), y: min(1-r.height, max(0, r.minY+delta.height)), width: r.width, height: r.height) }
        let sx = [-1,0,1,1,1,0,-1,-1][handle], sy = [-1,-1,-1,0,1,1,1,0][handle]
        if let ratio {
            let q = min(1_000_000, max(0.000001, ratio))
            let ax = sx < 0 ? r.maxX : sx > 0 ? r.minX : r.midX
            let ay = sy < 0 ? r.maxY : sy > 0 ? r.minY : r.midY
            let maxW = sx < 0 ? ax : sx > 0 ? 1-ax : 2*min(ax,1-ax)
            let maxH = sy < 0 ? ay : sy > 0 ? 1-ay : 2*min(ay,1-ay)
            var w = r.width + CGFloat(sx)*delta.width
            if sx == 0 || (sy != 0 && abs(delta.height*q) > abs(delta.width)) { w = (r.height + CGFloat(sy)*delta.height)*q }
            w = min(maxW, maxH*q, max(max(0.000001, 0.000001*q), w))
            let h = w/q
            return CGRect(x: sx < 0 ? ax-w : sx > 0 ? ax : ax-w/2, y: sy < 0 ? ay-h : sy > 0 ? ay : ay-h/2, width: w, height: h)
        }
        let x0 = sx < 0 ? min(r.maxX-0.000001,max(0,r.minX+delta.width)) : r.minX
        let x1 = sx > 0 ? max(r.minX+0.000001,min(1,r.maxX+delta.width)) : r.maxX
        let y0 = sy < 0 ? min(r.maxY-0.000001,max(0,r.minY+delta.height)) : r.minY
        let y1 = sy > 0 ? max(r.minY+0.000001,min(1,r.maxY+delta.height)) : r.maxY
        return CGRect(x: x0,y: y0,width: x1-x0,height: y1-y0)
    }
}

private struct PhotoCropCanvas: View {
    let image: NSImage
    let angle: Double
    @Binding var zoom: Double
    @Environment(\.displayScale) private var displayScale
    @State private var magnifyStart: Double?
    @Binding var rect: CGRect
    let aspect: Double?
    let denseGrid: Bool
    var onPreviewSize: ((Int) -> Void)? = nil
    @State private var dragStart: CGRect?
    var body: some View {
        GeometryReader { proxy in
            let pixels = PhotoEditStore.rotationBounds(image.size, degrees: angle).size
            let scale = min(max(1,proxy.size.width-32)/pixels.width, max(1,proxy.size.height-90)/pixels.height) * zoom
            let size = CGSize(width: pixels.width*scale, height: pixels.height*scale)
            let sourceEdge = max(image.size.width, image.size.height)
            let previewEdge = Int(ceil(min(sourceEdge, sourceEdge * scale * displayScale)))
            let box = CGRect(x: rect.minX*size.width, y: rect.minY*size.height, width: rect.width*size.width, height: rect.height*size.height)
            ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Image(nsImage: image).resizable().frame(width: image.size.width*scale,height: image.size.height*scale)
                    .rotationEffect(.degrees(-angle))
                    .frame(width: size.width,height: size.height).clipped()
                Path { p in p.addRect(CGRect(origin: .zero,size: size)); p.addRect(box) }
                    .fill(.black.opacity(0.58),style: FillStyle(eoFill: true)).allowsHitTesting(false)
                Rectangle().fill(.clear).contentShape(Rectangle()).frame(width: box.width,height: box.height)
                    .position(x: box.midX,y: box.midY).gesture(drag(-1,size: size, pixels: pixels)).accessibilityLabel("移动裁剪框")
                Path { p in
                    p.addRect(box)
                    let count = denseGrid ? 9 : 3
                    for i in 1..<count {
                        let x = box.minX+box.width*Double(i)/Double(count), y = box.minY+box.height*Double(i)/Double(count)
                        p.move(to: CGPoint(x: x,y: box.minY)); p.addLine(to: CGPoint(x: x,y: box.maxY))
                        p.move(to: CGPoint(x: box.minX,y: y)); p.addLine(to: CGPoint(x: box.maxX,y: y))
                    }
                }.stroke(.white.opacity(0.8),lineWidth: 1).allowsHitTesting(false)
                ForEach([1,3,5,7], id: \.self) { edge in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .frame(width: edge == 1 || edge == 5 ? box.width : 16, height: edge == 3 || edge == 7 ? box.height : 16)
                        .position(x: edge == 3 ? box.maxX : edge == 7 ? box.minX : box.midX, y: edge == 1 ? box.minY : edge == 5 ? box.maxY : box.midY)
                        .gesture(drag(edge,size: size, pixels: pixels))
                }
                ForEach(0..<8) { index in
                    let x = [box.minX,box.midX,box.maxX,box.maxX,box.maxX,box.midX,box.minX,box.minX][index]
                    let y = [box.minY,box.minY,box.minY,box.midY,box.maxY,box.maxY,box.maxY,box.midY][index]
                    RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: index % 2 == 0 ? 9 : (index == 1 || index == 5 ? 22 : 5),height: index % 2 == 0 ? 9 : (index == 3 || index == 7 ? 22 : 5))
                        .frame(width: 26,height: 26).contentShape(Rectangle()).position(x: x,y: y)
                        .gesture(drag(index,size: size, pixels: pixels)).accessibilityLabel("裁剪控制点 \(index+1)")
                }
                Text("\(Int(rect.width*pixels.width)) × \(Int(rect.height*pixels.height))")
                    .font(.caption.monospacedDigit()).padding(5).background(.black.opacity(0.7)).position(x: box.midX,y: min(size.height-12,box.maxY+18)).allowsHitTesting(false)
            }.coordinateSpace(name: "cropImage").frame(width: size.width,height: size.height)
                .padding(16).frame(minWidth: proxy.size.width, minHeight: max(1,proxy.size.height-42))
            }.defaultScrollAnchor(.center)
                .onChange(of: previewEdge, initial: true) { _, edge in onPreviewSize?(edge) }
                .padding(.bottom,42)
                .simultaneousGesture(MagnifyGesture().onChanged { value in
                    if magnifyStart == nil { magnifyStart = zoom }
                    zoom = min(32, max(1, magnifyStart! * value.magnification))
                }.onEnded { _ in magnifyStart = nil })
        }
    }
    private func drag(_ handle: Int,size: CGSize, pixels: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("cropImage")).onChanged { value in
            if dragStart == nil { dragStart = rect }
            let delta = CGSize(width: value.translation.width/size.width,height: value.translation.height/size.height)
            rect = CropGeometry.dragged(dragStart!, handle: handle, delta: delta, ratio: aspect.map { $0*pixels.height/pixels.width })
        }.onEnded { _ in dragStart = nil }
    }
}
