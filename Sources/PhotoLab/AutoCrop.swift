import SwiftUI
import CoreImage
import ImageIO

struct AutoCropCandidate: Identifiable {
    let id: Int
    let rect: CGRect // Top-left normalized in the displayed, rotated canvas.
    let score: Double
    let preview: NSImage
    let pixels: CGSize
}
struct AutoCropLimits {
    let size: CGSize
    let aspect: Double
    let area: Double
    var minimum: CGSize { let h = ceil(sqrt(size.width * size.height * area / aspect)); return CGSize(width: ceil(h * aspect), height: h) }
    var feasible: Bool { size.width > 0 && size.height > 0 && aspect.isFinite && aspect > 0 && area > 0 && area <= 1 && minimum.width <= size.width && minimum.height <= size.height }
}

actor AutoCropRunner {
    func run(source: URL, settings: PhotoAdjustments, pipeline: Int, rotation: Int, aspect: Double, area: Double,
             budget: Int = 90, manualOnly: Bool = false, baseline: @escaping @MainActor (Double) -> Void = { _ in },
             scorer: (@Sendable (URL) async throws -> Double)? = nil,
             snapshot: @escaping @MainActor (String, [AutoCropCandidate], Double) -> Void = { _,_,_ in },
             completed: @escaping @MainActor (String) -> Void = { _ in },
             progress: @escaping @MainActor (Int) -> Void) async throws -> [AutoCropCandidate] {
        if let ticket = WorkContext.ticket { try await ticket.checkpoint(); await ticket.stage("准备编辑后的图片…") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoLab-Crop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var a = settings; a.cropX = 0; a.cropY = 0; a.cropWidth = 1; a.cropHeight = 1
        let settingsForRender = a
        let control = WorkContext.ticket?.control ?? WorkControl(priority: 2)
        let base: CIImage = try await WorkScheduler.shared.run(.decode, control: control) {
            try await Task.detached(priority: .userInitiated) {
                try autoreleasepool {
                    var image = try PhotoEditStore.render(source, adjustments: settingsForRender, pipelineVersion: pipeline)
                    if rotation != 0 { image = image.oriented(rotation == 1 ? .right : rotation == 2 ? .down : .left) }
                    return CIImage(cgImage: try PhotoEditStore.cgImage(image, sixteenBit: true))
                }
            }.value
        }
        try Task.checkCancellation()
        let w = base.extent.width, h = base.extent.height
        let limits = AutoCropLimits(size: base.extent.size, aspect: aspect, area: area)
        guard manualOnly || limits.feasible else { throw CatalogError(message: "该比例无法保留指定面积，请降低最小面积。") }
        let worker = SemanticWorker(directory: folder, backend: "art")
        func scoreRect(_ rect: CGRect, id: Int) async throws -> AutoCropCandidate {
            try Task.checkCancellation()
            if let ticket = WorkContext.ticket { try await ticket.checkpoint() }
            let file = folder.appendingPathComponent("candidate.jpg")
            let data: Data = try autoreleasepool {
                var crop = base.cropped(to: CGRect(x: rect.minX, y: h-rect.maxY, width: rect.width, height: rect.height))
                crop = crop.transformed(by: CGAffineTransform(translationX: -crop.extent.minX, y: -crop.extent.minY))
                return try ImageCacheService.jpeg(crop)
            }
            try data.write(to: file)
            let score: Double
            if let scorer { score = try await scorer(file) }
            else {
                let reply = try await worker.request(["command":"score", "path":file.path], priority: manualOnly ? .interactive : .crop)
                guard let raw = reply.rawScore else { throw CatalogError(message: "裁剪评分结果无效") }; score = raw
            }
            try Task.checkCancellation()
            guard score.isFinite, (0...1).contains(score), let preview = NSImage(data: data) else { throw CatalogError(message: "裁剪评分结果无效") }
            return AutoCropCandidate(id: id, rect: CGRect(x: rect.minX/w,y: rect.minY/h,width: rect.width/w,height: rect.height/h), score: score, preview: preview, pixels: rect.size)
        }
        // Match the editor's lower-left pixel rounding before catalogue rotation.
        let sw = rotation % 2 == 0 ? w : h, sh = rotation % 2 == 0 ? h : w
        let px = floor(settings.cropX*sw+1e-7), py = floor(settings.cropY*sh+1e-7)
        let pw = max(1,floor(settings.cropWidth*sw+1e-7)), ph = max(1,floor(settings.cropHeight*sh+1e-7))
        let current = CropGeometry.rotated(CGRect(x: px/sw,y: 1-(py+ph)/sh,width: pw/sw,height: ph/sh), turns: rotation)
        let original = try await scoreRect(CGRect(x: 0,y: 0,width: w,height: h), id: -2)
        await baseline(original.score)
        if manualOnly {
            return [try await scoreRect(CGRect(x: (current.minX*w).rounded(),y: (current.minY*h).rounded(),width: (current.width*w).rounded(),height: (current.height*h).rounded()), id: -1)]
        }
        var search = AdaptiveCropSearch(size: base.extent.size, aspect: aspect, area: area, budget: max(10,min(2000,budget)))
        var candidates: [AutoCropCandidate] = []
        let started = Date()
        while let proposal = search.next() {
            try Task.checkCancellation()
            let fullFrame = proposal.rect == CGRect(x:0,y:0,width:w,height:h)
            let candidate: AutoCropCandidate
            if fullFrame {
                candidate = AutoCropCandidate(id:candidates.count,rect:original.rect,score:original.score,preview:original.preview,pixels:original.pixels)
            } else { candidate = try await scoreRect(proposal.rect, id:candidates.count) }
            candidates.append(candidate)
            search.record(candidate.score, countsAgainstBudget: !fullFrame)
            await progress(search.evaluationCount)
            await snapshot(proposal.phase, search.top().map { candidates[$0.id] }, Date().timeIntervalSince(started))
        }
        await completed(search.reason)
        return search.top().map { candidates[$0.id] }

    }
}

@MainActor final class AutoCropModel: ObservableObject {
    @Published var running = false
    @Published var count = 0
    @Published var budget = 90.0
    @Published var activeBudget = 90
    @Published var phase = ""
    @Published var completion = ""
    @Published var remainingSeconds: Int?
    @Published var baselineScore: Double?
    @Published var manualScore: Double?
    @Published var scoring = false
    @Published var results: [AutoCropCandidate] = []
    @Published var error: String?
    @Published var minimumPercent = 30.0 { didSet { if minimumPercent != oldValue { clear() } } }
    @Published var selected: Int?
    private var task: Task<Void,Never>?
    private var token = UUID()
    func clear() { task?.cancel(); task = nil; token = UUID(); running = false; results = []; error = nil; selected = nil; count = 0; baselineScore = nil; manualScore = nil; scoring = false; phase = ""; completion = ""; remainingSeconds = nil }
    func cancel() { clear() }
    func stop() {
        guard running else { return }
        task?.cancel(); task = nil; token = UUID(); running = false; remainingSeconds = nil
        completion = results.isEmpty ? "已停止，尚无候选结果" : "已停止，保留当前结果"
    }
    func cropChanged() {
        manualScore = nil; selected = nil
        if scoring { task?.cancel(); task = nil; token = UUID(); scoring = false }
    }
    func scoreCurrent(source: URL, settings: PhotoAdjustments, pipeline: Int, rotation: Int) {
        guard !running && !scoring else { return }
        task?.cancel(); token = UUID(); let key = token
        scoring = true; manualScore = nil; error = nil
        let ticket = TaskCenter.shared.begin("当前裁剪评分 · " + source.lastPathComponent, priority: 2, recorded: false, cancel: { [weak self] in if self?.token == key { self?.cancel() } }, retry: { [weak self] in self?.scoreCurrent(source: source, settings: settings, pipeline: pipeline, rotation: rotation) })
        task = Task { await ticket.run {
            defer { TaskCenter.shared.finish(ticket.id, cancelled: Task.isCancelled || token != key) }
            do {
                let result = try await AutoCropRunner().run(source: source, settings: settings, pipeline: pipeline, rotation: rotation, aspect: 1, area: 1, manualOnly: true, baseline: { [weak self] score in
                    guard let self, self.token == key else { return }; self.baselineScore = score
                }) { _ in }
                guard !Task.isCancelled, token == key else { return }
                manualScore = result.first?.score; scoring = false; task = nil
            } catch { if !Task.isCancelled && token == key { TaskCenter.shared.update(ticket.id, failure: error.localizedDescription); self.error = error.localizedDescription; scoring = false; task = nil } }
        } }
    }
    func start(source: URL, settings: PhotoAdjustments, pipeline: Int, rotation: Int, aspect: Double) {
        clear(); running = true; activeBudget = max(10,min(2000,Int(budget))); let key = token, area = minimumPercent/100, limit = activeBudget
        let ticket = TaskCenter.shared.begin("自动裁剪 · " + source.lastPathComponent, total: limit, priority: 2, recorded: false, cancel: { [weak self] in if self?.token == key { self?.stop() } }, retry: { [weak self] in self?.start(source: source, settings: settings, pipeline: pipeline, rotation: rotation, aspect: aspect) })
        task = Task { await ticket.run {
            defer { TaskCenter.shared.finish(ticket.id, cancelled: Task.isCancelled || token != key) }
            do {
                let result = try await AutoCropRunner().run(source: source, settings: settings, pipeline: pipeline, rotation: rotation, aspect: aspect, area: area, budget: limit, baseline: { [weak self] score in
                    guard let self, self.token == key else { return }; self.baselineScore = score
                }, snapshot: { [weak self] stage, best, elapsed in
                    guard let self, self.token == key else { return }
                    TaskCenter.shared.update(ticket.id, detail: stage)
                    self.phase = stage; self.results = best
                    self.remainingSeconds = self.count >= 3 ? Int(ceil(elapsed/Double(self.count)*Double(max(0,limit-self.count)))) : nil
                }, completed: { [weak self] reason in
                    guard let self, self.token == key else { return }; self.completion = reason
                }) { [weak self] value in
                    guard let self, self.token == key else { return }; self.count = value; TaskCenter.shared.update(ticket.id, completed: value)
                }
                guard !Task.isCancelled, token == key else { return }
                results = result; running = false; task = nil; remainingSeconds = nil
            } catch { if !Task.isCancelled && token == key { TaskCenter.shared.update(ticket.id, failure: error.localizedDescription); self.error = error.localizedDescription; running = false; task = nil; remainingSeconds = nil; completion = "搜索中断，保留已完成结果" } }
        } }
    }
}

struct AutoCropPanel: View {
    @ObservedObject var editor: PhotoEditorModel
    @ObservedObject var search: AutoCropModel
    var body: some View {
        let aspect = editor.cropAspect
        let limits = AutoCropLimits(size: editor.cropCanvasSize, aspect: aspect ?? 1, area: search.minimumPercent/100)
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("裁剪美学评分").font(.headline)
            Button(search.scoring ? "正在评分…" : "评分当前裁剪") {
                guard let source = editor.source, let draft = editor.cropDraft else { return }
                search.scoreCurrent(source: source, settings: draft, pipeline: editor.pipelineVersion, rotation: editor.current?.rotation ?? 0)
            }.disabled(search.running || search.scoring || editor.rendering)
            if search.scoring { ProgressView().controlSize(.small) }
            if let score = search.manualScore {
                Text("当前裁剪：\(score*100, specifier: "%.3f") 分").font(.caption)
                if let baseline = search.baselineScore { Text("较原图 \((score-baseline)*100, specifier: "%+.3f") 分").font(.caption) }
            }
            Text("原图分为相同调色、旋转下的完整画面评分。改变裁剪后需重新评分；自由比例也可评分。").font(.caption2).foregroundStyle(.secondary)
            Divider()
            Text("自动搜索裁剪").font(.headline)
            Text("按上方宽:高搜索；4:3 为横幅，3:4 为竖幅。").font(.caption).foregroundStyle(.secondary)
            PhotoAdjustmentControl(title: "最小保留面积 %", value: $search.minimumPercent, range: 1...100, step: 1, sliderEditing: { _ in })
            if aspect == nil { Text("请先选择固定宽高比。").font(.caption) }
            else if limits.feasible {
                Text("预计尺寸下限 ≈ \(Int(limits.minimum.width)) × \(Int(limits.minimum.height)) px").font(.caption)
                Text("按旋转后的完整可用画面计算，最终尺寸以候选为准。").font(.caption2).foregroundStyle(.secondary)
            } else { Text("该比例无法保留指定面积，请降低最小面积。").font(.caption).foregroundStyle(.orange) }
            HStack {
                ForEach([30,90,300], id: \.self) { value in
                    Button(value == 30 ? "快速 30" : value == 90 ? "标准 90" : "深入 300") { search.budget = Double(value) }
                }
            }.disabled(search.running)
            PhotoAdjustmentControl(title: "搜索预算（张）", value: Binding(get: { search.budget }, set: { search.budget = $0.rounded() }), range: 10...2000, step: 1, sliderEditing: { _ in }, decimalPlaces: 0).disabled(search.running)
            Text("原图基准不计入预算；重复框复用评分。预算越大，覆盖和细化越充分。").font(.caption2).foregroundStyle(.secondary)
            if search.running {
                ProgressView(value: Double(search.count), total: Double(search.activeBudget))
                Text(search.count == 0 ? "准备完整画面并加载美学模型…" : "\(search.phase) · 已评分 \(search.count) / \(search.activeBudget)").font(.caption)
                if let seconds = search.remainingSeconds { Text("按当前速度，预计最多还需 \(seconds/60) 分 \(seconds%60) 秒").font(.caption2).foregroundStyle(.secondary) }
                Button("停止并保留结果") { search.stop() }
            } else {
                Button("开始搜索") {
                    guard let source = editor.source, let draft = editor.cropDraft, let aspect else { return }
                    search.start(source: source, settings: draft, pipeline: editor.pipelineVersion, rotation: editor.current?.rotation ?? 0, aspect: aspect)
                }.disabled(aspect == nil || !limits.feasible || editor.rendering || search.scoring)
            }
            if !search.running && !search.completion.isEmpty { Text(search.completion).font(.caption).foregroundStyle(.secondary) }
            if let error = search.error { Text(error).font(.caption).foregroundStyle(.red) }
            if let baseline = search.baselineScore {
                Text("原图：\(baseline*100, specifier: "%.3f") 分").font(.caption)
            }
            if !search.results.isEmpty {
                Text("\(search.running ? "当前最佳" : "结果") · \(search.count) 次评分 · \(search.results.count) 个候选").font(.caption)
                if let baseline = search.baselineScore, let best = search.results.first {
                    Text("最佳较原图 \((best.score-baseline)*100, specifier: "%+.3f") 分").font(.caption).bold()
                    if best.score <= baseline { Text(search.running ? "目前尚未超过原图分数。" : "本次未找到比原图更高分的方案。").font(.caption).foregroundStyle(.secondary) }
                }
                Text("美学原始分 ×100；优先保留不同构图。点击预览，再应用裁剪。").font(.caption2).foregroundStyle(.secondary)
                ForEach(Array(search.results.enumerated()), id: \.element.id) { rank, candidate in
                    Button {
                        editor.displayCrop = candidate.rect; search.selected = candidate.id
                    } label: {
                        VStack(alignment: .leading) {
                            Image(nsImage: candidate.preview).resizable().scaledToFit().frame(maxHeight: 150)
                            Text("\(rank+1).  \(candidate.score*100, specifier: "%.3f") 分  \(search.selected == candidate.id ? "· 已预览" : "")")
                            if let baseline = search.baselineScore { Text("较原图 \((candidate.score-baseline)*100, specifier: "%+.3f") 分").font(.caption) }
                            Text("\(Int(candidate.pixels.width)) × \(Int(candidate.pixels.height)) · 保留 \(candidate.rect.width*candidate.rect.height*100, specifier: "%.1f")%").font(.caption)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).padding(6).background(search.selected == candidate.id ? Color.accentColor.opacity(0.15) : Color.clear).cornerRadius(6)
                }
            }
        }
    }
}
