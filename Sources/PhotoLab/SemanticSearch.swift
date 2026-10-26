import AppKit
import SwiftUI
import CryptoKit
import CoreImage
import ImageIO

struct SemanticHit: Decodable, Identifiable {
    var id: String
    var score: Double
    var siglipScore: Double?
    var qwenScore: Double?
    var siglipRank: Double?
    var qwenRank: Double?
}
struct SemanticReply: Decodable {
    var ok: Bool
    var error: String?
    var fingerprints: [String: String]?
    var groups: [[String]]?
    var hits: [SemanticHit]?
    var seconds: Double?
    var device: String?
    var searched: Int?
    var scoreKind: String?
    var notice: String?
    var rawScore: Double?
    var artScores: [String: Double]?
}

private struct IndexInput: Sendable {
    let offset: Int
    let asset: Asset
    let url: URL?
}

// One local process; serialized JSON-lines calls never block the UI actor.
final class SemanticWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "photolab.siglip", qos: .utility)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private let directory: URL
    private let backend: String
    init(directory: URL, backend: String) { self.directory = directory; self.backend = backend }
    deinit { if process?.isRunning == true { process?.terminate() } }

    private func start() throws {
        if process?.isRunning == true { return }
        guard let resources = Bundle.main.resourceURL else { throw CatalogError(message: "找不到 AI 运行资源") }
        let folder = resources.appendingPathComponent("AI")
        let shared = backend.hasPrefix("shared-")
        let scoring = backend == "art" || backend == "quality" || backend == "shared-art"
        let config = try AIInstallation.configuration()
        guard let python = config[scoring ? "artPython" : "python"], let model = config[scoring ? "artModel" : backend == "qwen" ? "qwenModel" : "model"] ?? (shared ? config["qwenModel"] : nil), FileManager.default.isExecutableFile(atPath: python) else {
            throw CatalogError(message: "本地 AI 尚未安装，请打开“选片 → AI 模型管理…”下载所需模型。")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("worker.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let errorLog = try FileHandle(forWritingTo: log); try errorLog.seekToEnd()
        let task = Process(); let stdin = Pipe(); let stdout = Pipe()
        task.executableURL = URL(fileURLWithPath: python)
        task.arguments = ["-B", "-u", folder.appendingPathComponent((backend == "art" || backend == "quality") ? "art_worker.py" : "worker.py").path, model, directory.appendingPathComponent((backend == "art" || backend == "quality") ? "scores.sqlite" : "vectors.sqlite").path, backend]
        let runtimeConfig = directory.appendingPathComponent("runtime-config.json")
        try JSONEncoder().encode(config).write(to: runtimeConfig, options: .atomic)
        if shared { task.arguments = ["-B", "-u", folder.appendingPathComponent("shared_worker.py").path, runtimeConfig.path, backend == "shared-art" ? "art" : "embedding"] }
        if backend == "fusion" { task.arguments?.append(config["qwenModel"] ?? "") }
        task.environment = ProcessInfo.processInfo.environment.merging(["PHOTOLAB_QWEN_COREML": config["qwenCoreML"] ?? "", "HF_HUB_OFFLINE": "1", "TOKENIZERS_PARALLELISM": "false", "HF_HUB_DISABLE_TELEMETRY": "1"]) { _, new in new }
        task.standardInput = stdin; task.standardOutput = stdout; task.standardError = errorLog
        task.qualityOfService = .utility
        try task.run()
        process = task; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading; buffer = Data()
    }
    func request(_ request: [String: Any], priority: ModelRequestPriority? = nil) async throws -> SemanticReply {
        if !backend.hasPrefix("shared-"), let ticket = WorkContext.ticket {
            try await ticket.checkpoint()
            let command = request["command"] as? String ?? ""
            await ticket.stage(command == "status" ? "读取已有索引…" : command == "cluster" ? "更新相似照片分组…" : "等待模型 / 本地推理…")
        }
        if !backend.hasPrefix("shared-") {
            return try await ModelService.request(backend: backend, directory: directory, request: request, priority: priority ?? (request["command"] as? String == "search" ? .interactive : .background))
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let data = try JSONSerialization.data(withJSONObject: request) + Data([10])
                    try self.start()
                    guard let process = self.process, let input = self.input, let output = self.output else { throw CatalogError(message: "无法启动检索进程") }
                    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: timeout)
                    defer { timeout.cancel() }
                    try input.write(contentsOf: data)
                    while !self.buffer.contains(10) {
                        let chunk = output.availableData
                        guard !chunk.isEmpty else { throw CatalogError(message: "本地检索进程退出或超时，可重试；详情见 SemanticSearch/worker.log") }
                        self.buffer.append(chunk)
                    }
                    let end = self.buffer.firstIndex(of: 10)!
                    let line = self.buffer.prefix(upTo: end); self.buffer.removeSubrange(...end)
                    let reply = try JSONDecoder().decode(SemanticReply.self, from: line)
                    if reply.ok { continuation.resume(returning: reply) }
                    else { continuation.resume(throwing: CatalogError(message: reply.error ?? "本地检索失败")) }
                } catch {
                    self.stopProcess()
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    private func stopProcess() {
        if let process, process.isRunning { process.terminate(); process.waitUntilExit() }
        try? input?.close(); try? output?.close()
        process = nil; input = nil; output = nil; buffer = Data()
    }
    func shutdown() async {
        await withCheckedContinuation { continuation in
            queue.async { self.stopProcess(); continuation.resume() }
        }
    }

}

@MainActor final class SemanticSearchModel: ObservableObject {
    init(backend: String = "fusion") { self.backend = backend }
    @Published var enabled = false
    @Published var backend = "fusion" {
        didSet { worker = nil; fingerprints = [:]; indexStatusLoaded = false; generation = UUID() }
    }
    var modelName: String {
        switch backend { case "fusion": "混合 · SigLIP + Qwen"; case "qwen": "Qwen3-VL 2B"; case "art": "艺术评分"; case "quality": "质量评分"; default: "SigLIP 2" }
    }
    private var generation = UUID()
    @Published var text = ""
    @Published var busy = false
    @Published var indexing = false
    private var monitoring: WorkTicket?
    @Published var message = "SigLIP 2 Base · 本地照片语义检索" {
        didSet { if let monitoring { TaskCenter.shared.update(monitoring.id, detail: message) } }
    }
    @Published var error: String?
    @Published var fingerprints: [String: String] = [:]
    @Published var hits: [SemanticHit] = [] {
        didSet {
            scores = Dictionary(uniqueKeysWithValues: hits.map { ($0.id, $0.score) })
            details = Dictionary(uniqueKeysWithValues: hits.map { ($0.id, $0) })
        }
    }
    @Published private(set) var scores: [String: Double] = [:]
    @Published private(set) var fused = false
    private var details: [String: SemanticHit] = [:]
    var scoreLabel: String { fused ? "混合相关度" : "相似度" }
    func scoreHelp(_ id: String) -> String {
        guard fused, let hit = details[id] else {
            return "余弦相似度，范围 −1 到 1；越大越相似，不是匹配概率。仅在同一模型、同一次查询中比较。"
        }
        var lines: [String] = []
        if let score = hit.siglipScore, let rank = hit.siglipRank { lines.append(String(format: "SigLIP：%.3f · 第 %g 名", score, rank)) }
        if let score = hit.qwenScore, let rank = hit.qwenRank { lines.append(String(format: "Qwen：%.3f · 第 %g 名", score, rank)) }
        lines.append("按已有模型的 RRF 相关度取平均；缺失模型不计分。不是概率或余弦相似度，仅在本次查询中比较。")
        return lines.joined(separator: "\n")
    }

    @Published var rawScores: [String: Double] = [:]
    @Published var failedIDs: Set<String> = []
    @Published var runScope = ""
    @Published var revision = 0
    @Published var reference: Asset?
    private var task: Task<Void, Never>?
    private var worker: SemanticWorker?
    private var directory: URL?
    @Published var autoPaused = false
    private var autoAttempted: [String: String] = [:]
    private var indexStatusLoaded = false
    private var clusteredRevision = -1
    private var clusteredThreshold: Double?

    func automaticallyIndex(_ library: LibraryModel) async {
        guard TaskCenter.shared.loaded, !ModelBatchQueue.shared.has(backend: backend), backend == "siglip", !busy, !library.loading, library.rootsResolved, !library.scanning, !library.checkingAnalysisEdits else { return }
        let photos = library.assets.filter { !$0.video && !$0.missing }
        guard !photos.isEmpty else { return }
        let roots = Dictionary(uniqueKeysWithValues: library.roots.map { ($0.id, $0.path) })
        let attempts = autoAttempted
        var scope = FilterState(); scope.rootID = library.filter.rootID; scope.folder = library.filter.folder; scope.recursive = library.filter.recursive
        let pending = await Task.detached(priority: .utility) {
            let pending = photos.filter { attempts[$0.id] != Self.fingerprint($0) + (roots[$0.rootID] ?? "") }
            return pending.filter { scope.matches($0) } + pending.filter { !scope.matches($0) }
        }.value
        guard !Task.isCancelled, !busy else { return }
        if !pending.isEmpty && !autoPaused {
            for photo in pending { autoAttempted[photo.id] = Self.fingerprint(photo) + (roots[photo.rootID] ?? "") }
            library.indexCaptureDates()
            index(library, photos: pending, scopeName: "自动分析新增照片", priority: 0)
        } else if clusteredRevision != library.contentRevision || clusteredThreshold != library.similarityThreshold {
            // busy is part of the view's indexing task identity. Toggling it
            // here cancels this very regroup request before it can finish.
            await updateGroups(library, worker: engine(library))
        }
    }
    func automaticallyRefreshEdits(_ library: LibraryModel) async {
        guard TaskCenter.shared.loaded, indexStatusLoaded, !ModelBatchQueue.shared.has(backend: backend), ["qwen", "art", "quality"].contains(backend), !busy, !autoPaused,
              !library.loading, library.rootsResolved, !library.checkingAnalysisEdits, !library.scanning else { return }
        let photos = library.assets.filter { !$0.video && !$0.missing && ($0.analysisEditToken != nil || $0.analysisTracksEdits == true || library.analysisChangedIDs.contains($0.id)) }
        // Wait for persisted results, then enqueue only changed or missing versions.
        // Session attempts suppress repeated failures; they do not establish freshness.
        let pending = photos.filter { !valid($0) && autoAttempted[$0.id] != Self.fingerprint($0, backend: backend) }
        guard !pending.isEmpty else { return }
        for photo in pending { autoAttempted[photo.id] = Self.fingerprint(photo, backend: backend) }
        index(library, photos: pending, scopeName: "更新编辑后的照片", priority: 0)
    }
    func resumeAutomatic(_ library: LibraryModel) {
        autoPaused = false; autoAttempted = [:]
        Task { await automaticallyIndex(library) }
    }
    func refreshSimilarityGroups(_ library: LibraryModel) async {
        guard backend == "siglip", !library.loading, library.rootsResolved, !library.checkingAnalysisEdits else { return }
        // A threshold edit uses existing vectors even if indexing is paused/queued.
        await updateGroups(library, worker: engine(library), interactive: true)
    }
    private func updateGroups(_ library: LibraryModel, worker: SemanticWorker, interactive: Bool = false) async {
        let snapshot = library.assets; let revision = library.contentRevision
        let threshold = library.similarityThreshold
        let owned = WorkContext.ticket == nil ? TaskCenter.shared.begin("相似照片分组", priority: interactive ? 2 : 0) : nil
        let ticket = WorkContext.ticket ?? owned
        defer { if let owned { TaskCenter.shared.finish(owned.id, cancelled: Task.isCancelled) } }
        do {
            let photos = await Task.detached(priority: .utility) {
                snapshot.filter { !$0.video && !$0.missing }.map { asset -> [String: Any] in
                    var item: [String: Any] = ["id": asset.id, "fingerprint": Self.fingerprint(asset), "root": asset.rootID, "folder": asset.folder, "day": CaptureDates.day(asset.captureDate)]
                    if let date = asset.captureDate { item["capture"] = date }
                    return item
                }
            }.value
            if let ticket { try await ticket.checkpoint(); await ticket.stage("更新相似照片分组…") }
            let reply = try await WorkContext.$ticket.withValue(ticket) { try await worker.request(["command": "cluster", "photos": photos, "threshold": threshold], priority: interactive ? .interactive : .background) }
            try Task.checkCancellation()
            if revision == library.contentRevision && threshold == library.similarityThreshold {
                library.setSimilarityGroups(reply.groups ?? [], snapshot: snapshot)
                clusteredRevision = revision
                clusteredThreshold = threshold
                if self.error?.hasPrefix("相似照片分组未完成：") == true { self.error = nil }
            }
        } catch {
            // A cancelled/failed computation is not an applied cache entry.
            // Keep the last successful revision so the same threshold can retry.
            if error is WorkYield || error is CancellationError { return }
            if let ticket { TaskCenter.shared.update(ticket.id, failure: error.localizedDescription) }
            self.error = "相似照片分组未完成：" + error.localizedDescription
        }
    }


    nonisolated static func fingerprint(_ asset: Asset) -> String {
        asset.analysisFingerprint
    }
    nonisolated static func fingerprint(_ asset: Asset, backend: String) -> String {
        backend == "quality" ? asset.qualityFingerprint : backend == "art" ? asset.artFingerprint : Self.fingerprint(asset)
    }
    func valid(_ asset: Asset) -> Bool { !asset.video && fingerprints[asset.id] == Self.fingerprint(asset, backend: backend) }
    private func engine(_ library: LibraryModel) -> SemanticWorker {
        if let worker { return worker }
        let base = library.catalog.directory.appendingPathComponent("SemanticSearch")
        let directory = (backend == "art" || backend == "quality") ? library.catalog.directory.appendingPathComponent(backend == "quality" ? "QualityScores" : "ArtScores") : backend == "qwen" ? base.appendingPathComponent("Qwen") : base
        self.directory = directory
        let worker = SemanticWorker(directory: directory, backend: backend); self.worker = worker
        return worker
    }
    func refresh(_ library: LibraryModel) async {
        guard !busy else { return }
        indexStatusLoaded = false
        busy = true
        let ticket = TaskCenter.shared.begin("读取 " + modelName + " 索引", priority: 0)
        defer { busy = false; TaskCenter.shared.finish(ticket.id, error: error); ModelBatchQueue.shared.pump() }
        do {
            let reply = try await WorkContext.$ticket.withValue(ticket) { try await engine(library).request(["command": "status"]) }
            if let directory, let bytes = try? Data(contentsOf: directory.appendingPathComponent("failed.json")),
               let ids = try? JSONDecoder().decode(Set<String>.self, from: bytes) { failedIDs = ids }
            fingerprints = reply.fingerprints ?? [:]; rawScores = reply.artScores ?? [:]; revision += 1; error = nil
            indexStatusLoaded = true
            if backend == "quality" { library.setQualityScores(rawScores, fingerprints: fingerprints) }
            else if backend == "art" { library.setArtScores(rawScores, fingerprints: fingerprints) }
        }
        catch { self.error = error.localizedDescription }
    }
    func index(_ library: LibraryModel, photos scope: [Asset]? = nil, scopeName: String = "所有素材", retryOnly: Bool = false, priority: Int = 1) {
        let requestedPhotos = (scope ?? library.assets).filter { !$0.video && (!retryOnly || failedIDs.contains($0.id)) }
        guard !requestedPhotos.isEmpty else { return }
        let backend = backend
        let title = backend == "art" ? "艺术评分" : backend == "quality" ? "质量评分" : "\(modelName) 索引"
        let key = backend + "|" + requestedPhotos.map { $0.id + ":" + Self.fingerprint($0, backend: backend) }.sorted().joined(separator: "|")
        ModelBatchQueue.shared.enqueue(key: key, title: title + " · " + scopeName, total: requestedPhotos.count, priority: priority,
            recipe: WorkRecipe(kind: "index", ids: requestedPhotos.map(\.id), backend: backend), ready: { [self] in !busy },
            start: { [self] ticket in startIndex(library, requestedPhotos: requestedPhotos, scopeName: scopeName, ticket: ticket) },
            cancel: { [weak self] in self?.cancel() })
    }
    private func startIndex(_ library: LibraryModel, requestedPhotos: [Asset], scopeName: String, ticket: WorkTicket) {
        autoPaused = false
        busy = true; indexing = true; error = nil; hits = []
        let worker = engine(library)
        let backend = backend
        runScope = scopeName
        let rootPaths = Dictionary(uniqueKeysWithValues: library.roots.map { ($0.id,$0.path) })
        monitoring = ticket; message = "检查编辑版本与已有索引…"
        task = Task { await ticket.run {
            let start = Date(); var done = 0; var skipped = 0; var failures = 0; var firstError: String?
            defer {
                let yielding = ticket.control.shouldYield && !ticket.control.cancelled && !Task.isCancelled
                if !yielding { TaskCenter.shared.finish(ticket.id, cancelled: Task.isCancelled) }
                monitoring = nil; busy = false; indexing = false; task = nil; workerRelease(); revision += 1
                if (backend == "art" || backend == "quality") && library.artSort { library.rebuild() }
                if yielding { ModelBatchQueue.shared.yielded(ticket.id) } else { ModelBatchQueue.shared.finished(ticket.id) }
            }
            do {
                try await ticket.checkpoint()
                await library.refreshAnalysisEdits(ids: Set(requestedPhotos.map(\.id)))
                try Task.checkCancellation()
                let current = Dictionary(uniqueKeysWithValues: library.assets.map { ($0.id, $0) })
                let photos = requestedPhotos.map { current[$0.id] ?? $0 }
                let status = try await worker.request(["command": "status"])
                fingerprints = status.fingerprints ?? [:]
                indexStatusLoaded = true
                if backend == "siglip" { await updateGroups(library, worker: worker) }
                if backend == "art" || backend == "quality" {
                    rawScores = status.artScores ?? [:]
                    if backend == "quality" { library.setQualityScores(rawScores, fingerprints: fingerprints) }
                    else { library.setArtScores(rawScores, fingerprints: fingerprints) }
                }
                guard let directory else { throw CatalogError(message: "找不到分析预览目录") }
                let known = fingerprints
                let pending = await Task.detached(priority: .utility) {
                    photos.enumerated().filter { known[$0.element.id] != Self.fingerprint($0.element, backend: backend) }.map { pair in
                        IndexInput(offset: pair.offset, asset: pair.element, url: rootPaths[pair.element.rootID].map { path in URL(fileURLWithPath:path, isDirectory: true).appendingPathComponent(pair.element.preferred.relativePath, isDirectory: false) })
                    }
                }.value
                skipped = photos.count - pending.count
                TaskCenter.shared.update(ticket.id, detail: "已复用 \(skipped) 项，准备分析 \(pending.count) 项", completed: skipped, total: photos.count)
                do {
                    try await runPrefetched(pending, prepare: { input in
                        try await ticket.checkpoint()
                        guard let url = input.url else { throw CatalogError(message: "找不到原片位置") }
                        let preview = PreparedPreview(directory: directory)
                        try await ImageCacheService.shared.analysis(asset: input.asset, url: url, destination: preview.url)
                        try Task.checkCancellation()
                        return preview
                    }, consume: { input, prepared in
                        try await ticket.checkpoint()
                        let asset = input.asset
                        message = "\(backend == "quality" ? "质量评分" : backend == "art" ? "艺术评分" : "建立索引") \(done + failures + 1)/\(pending.count) · \(asset.name)"
                        do {
                            let preview = try prepared.get()
                            try Task.checkCancellation()
                            let fingerprint = Self.fingerprint(asset, backend: backend)
                            let reply = try await worker.request(["command": "index", "id": asset.id, "fingerprint": fingerprint, "path": preview.url.path])
                            if let currentAsset = library.assets.first(where: { $0.id == asset.id }), currentAsset.analysisFingerprint != asset.analysisFingerprint { return }
                            fingerprints[asset.id] = fingerprint; let hadFailure = failedIDs.remove(asset.id) != nil; revision += 1; done += 1
                            if let raw = reply.rawScore {
                                rawScores[asset.id] = raw
                                if backend == "quality" { library.setQualityScore(asset.id, raw: raw, fingerprint: fingerprint) }
                                else { library.setArtScore(asset.id, raw: raw, fingerprint: fingerprint) }
                            }
                            TaskCenter.shared.update(ticket.id, completed: skipped + done + failures)
                            message += " · \(reply.device ?? "")"
                            if hadFailure { await saveFailures() }
                            if backend == "siglip", done % 50 == 0, !Task.isCancelled { await updateGroups(library, worker: worker) }
                        } catch {
                            if error is WorkYield { throw error }
                            if Task.isCancelled { throw CancellationError() }
                            failures += 1; failedIDs.insert(asset.id); revision += 1
                            TaskCenter.shared.update(ticket.id, completed: skipped + done + failures, failure: asset.name + "：" + error.localizedDescription)
                            await saveFailures()
                            if firstError == nil { firstError = "\(asset.name)：\(error.localizedDescription)" }
                            if failures >= 3 && done == 0 { throw error }
                        }
                    })
                } catch is CancellationError { /* Current inference is committed; prefetched work is discarded. */ }
                message = "\(Task.isCancelled ? "已暂停" : "分析完成") · 新建 \(done) · 复用 \(skipped) · 失败 \(failures) · \(Int(Date().timeIntervalSince(start))) 秒"
                error = firstError
                try await ticket.checkpoint()
                if backend == "siglip" { await updateGroups(library, worker: worker) }
            } catch {
                if !(error is CancellationError) && !(error is WorkYield) { self.error = error.localizedDescription; TaskCenter.shared.update(ticket.id, failure: error.localizedDescription) }
                message = "分析未完成，已完成部分保留，可继续。"
            }
        } }
    }
    private func saveFailures() async {
        guard let directory else { return }
        let failures = failedIDs
        await Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(failures) {
                try? data.write(to: directory.appendingPathComponent("failed.json"), options: .atomic)
            }
        }.value
    }
    private func workerRelease() { worker = nil }
    func cancel() { autoPaused = true; task?.cancel(); message = "正在完成当前照片后暂停…" }
    func resetResults(_ library: LibraryModel) {
        generation = UUID()
        if !indexing { busy = false }
        hits = []; fused = false; error = nil; library.semanticIDs = nil
    }
    func openSimilar(_ asset: Asset) { reference = asset; text = ""; enabled = true }

    func search(_ library: LibraryModel, similar: Bool = false) {
        guard !indexing, similar || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if !similar { reference = nil }
        task?.cancel()
        let current = UUID(); generation = current
        busy = true; error = nil; hits = []; library.semanticIDs = []; message = "正在本地检索…"
        let worker = engine(library)
        // Existing folder/rating/tag filters apply; stale vectors never participate.
        let snapshot = library.assets; let scope = library.filter; let query = text; let referenceID = similar ? reference?.id : nil
        let ticket = TaskCenter.shared.begin(similar ? "以图搜图 · " + modelName : "语义检索 · " + query, priority: 2, recorded: false, cancel: { [weak self] in if self?.generation == current { self?.task?.cancel() } })
        monitoring = ticket
        task = Task { await ticket.run {
            defer { TaskCenter.shared.finish(ticket.id, cancelled: Task.isCancelled || generation != current); if generation == current { busy = false; task = nil; monitoring = nil } }
            do {
                let candidates = await Task.detached(priority: .userInitiated) {
                    Dictionary(uniqueKeysWithValues: snapshot.filter { !$0.video && scope.matchesScope($0) }.map { ($0.id, Self.fingerprint($0)) })
                }.value
                guard generation == current else { return }
                var request: [String: Any] = ["command": "search", "candidates": candidates, "text": query]
                if let referenceID { request["reference"] = referenceID }
                let reply = try await worker.request(request)
                guard generation == current else { return }
                fused = reply.scoreKind == "fusion"
                hits = reply.hits ?? []
                library.semanticIDs = hits.map(\.id)
                message = "在 \(reply.searched ?? 0) 张已索引照片中检索 · \(reply.device ?? "") · \(String(format: "%.2f", reply.seconds ?? 0)) 秒 · 全部 \(hits.count) 张，按相似度排序"
                if let notice = reply.notice { message = notice + " " + message }
            } catch { if generation == current && !(error is CancellationError) { self.error = error.localizedDescription; message = "检索未完成"; TaskCenter.shared.update(ticket.id, failure: error.localizedDescription) } }
        } }
    }
}

// Compatibility entry point; production indexing passes the complete Asset to the shared service.
func semanticPreview(url: URL, raw: Bool, rotation: Int, destination: URL, cacheKey: String? = nil, maxDimension: CGFloat = 960) async throws {
    let asset = try await Task.detached(priority: .utility) { () -> Asset in
        let source = try EditSource.read(url)
        var asset = Asset(id: cacheKey ?? url.path, rootID: "preview", folder: "", name: url.lastPathComponent, video: false,
                          files: [MediaFile(relativePath: url.lastPathComponent, size: Int64(source.size), modified: source.modified)], date: source.modified)
        asset.rotation = rotation; asset.analysisEditToken = try PhotoEditStore.analysisRevision(sources: [url])
        return asset
    }.value
    try await ImageCacheService.shared.analysis(asset: asset, url: url, destination: destination)
}

// Rule queries are independent of the top search box and of other rule outcomes.
// Cached scores survive comparator/threshold edits; changing scope/index invalidates them.
@MainActor final class RuleEmbeddingSearchModel: ObservableObject {
    typealias Request = (String, URL, [String: Any]) async throws -> SemanticReply
    private let send: Request
    init(send: @escaping Request = { backend, directory, request in
        try await ModelService.request(backend: backend, directory: directory, request: request, priority: .interactive)
    }) { self.send = send }
    @Published private(set) var pending: Set<EmbeddingFilterQuery> = []
    @Published private(set) var errors: [EmbeddingFilterQuery: String] = [:]
    @Published private(set) var notices: [EmbeddingFilterQuery: String] = [:]
    @Published private(set) var counts: [EmbeddingFilterQuery: Int] = [:]
    @Published var retryRevision = 0
    private var cache: [EmbeddingFilterQuery: [String: Double]] = [:]
    private var cacheIdentity = ""
    private var generation = UUID()

    func refresh(_ library: LibraryModel, indexIdentity: String) async {
        let token = UUID(); generation = token
        let revision = library.contentRevision, scope = library.filter.scopeIdentity
        let identity = "\(revision)|\(scope)|\(indexIdentity)|\(retryRevision)"
        let queries = library.filter.embeddingQueries
        if identity != cacheIdentity { cache = [:]; errors = [:]; notices = [:]; counts = [:]; cacheIdentity = identity }
        // Bound score matrices to the active rules rather than every historical query.
        cache = cache.filter { queries.contains($0.key) }
        errors = errors.filter { queries.contains($0.key) }
        notices = notices.filter { queries.contains($0.key) }
        counts = counts.filter { queries.contains($0.key) }
        pending = Set(queries.filter { cache[$0] == nil })
        library.setRuleEmbeddingScores(cache, revision: revision, scope: scope)
        guard !queries.isEmpty, !library.loading else { return }
        do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
        let snapshot = library.assets, filter = library.filter
        let candidates = await Task.detached(priority: .userInitiated) {
            Dictionary(uniqueKeysWithValues: snapshot.filter { !$0.video && filter.matchesScope($0) }.map { ($0.id, $0.analysisFingerprint) })
        }.value
        guard !Task.isCancelled, generation == token else { return }
        let base = library.catalog.directory.appendingPathComponent("SemanticSearch")
        var fingerprints: [String: [String: String]] = [:]
        for query in queries where cache[query] == nil {
            guard !Task.isCancelled, generation == token else { return }
            do {
                let backends = query.backend == "fusion" ? ["siglip", "qwen"] : [query.backend]
                var available: [String: String] = [:]
                var statusErrors: [String] = []
                for backend in backends {
                    do {
                        if fingerprints[backend] == nil {
                            let directory = backend == "qwen" ? base.appendingPathComponent("Qwen") : base
                            let reply = try await send(backend, directory, ["command": "status"])
                            fingerprints[backend] = reply.fingerprints ?? [:]
                        }
                        for (id, fp) in candidates where fingerprints[backend]?[id] == fp { available[id] = fp }
                    } catch {
                        if error is CancellationError { throw error }
                        statusErrors.append(error.localizedDescription)
                    }
                }
                try Task.checkCancellation()
                let scores: [String: Double]
                if available.isEmpty {
                    if !statusErrors.isEmpty { throw CatalogError(message: statusErrors.joined(separator: "；")) }
                    scores = [:]
                } else {
                    let directory = query.backend == "qwen" ? base.appendingPathComponent("Qwen") : base
                    let reply = try await send(query.backend, directory,
                        ["command": "search", "text": query.text, "candidates": candidates, "rankFusion": true])
                    scores = Dictionary(uniqueKeysWithValues: (reply.hits ?? []).map { ($0.id, $0.score) })
                    guard !Task.isCancelled, generation == token else { return }
                    notices[query] = reply.notice
                }
                guard !Task.isCancelled, generation == token else { return }
                cache[query] = scores; counts[query] = scores.count; errors[query] = nil
                pending.remove(query)
                library.setRuleEmbeddingScores(cache, revision: revision, scope: scope)
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                errors[query] = error.localizedDescription; pending.remove(query)
            }
        }
    }
}
