import AppKit
import SwiftUI

final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

struct ExportWorkFile: Codable, Identifiable {
    var id = UUID()
    var sources: [URL]
    var destination: URL
    var edited: Bool
    var rotation: Int
    var options: PhotoExportOptions? = nil
}
struct ExportWorkPlan: Codable {
    var destination: URL
    var remaining: [ExportWorkFile]
    var uncertain: ExportWorkFile? = nil
}

@MainActor final class LibraryModel: ObservableObject {
    let catalog: Catalog
    enum CacheBuildKind { case thumbnails, originals }
    @Published private(set) var buildingCache = false
    @Published private(set) var cacheBuildStatus = ""
    private var scanTicket: WorkTicket?
    private var exportTicket: WorkTicket?
    private var cacheBuildTask: Task<Void, Never>?
    func stopCacheBuild() {
        cacheBuildTask?.cancel()
        cacheBuildStatus = "正在停止缓存构建，等待当前文件完成…"
    }
    func buildCache(root: LibraryRoot, folder: String? = nil, kind: CacheBuildKind) {
        guard !buildingCache else { return }
        let selected = assets.filter { asset in
            asset.rootID == root.id && (folder == nil || asset.folder == folder! || asset.folder.hasPrefix(folder! + "/"))
        }
        let name = folder ?? root.name
        let title = kind == .thumbnails ? "缩略图缓存" : "原片缓存"
        buildingCache = true; cacheBuildStatus = "准备构建\(title) · \(name)"
        let recipe = WorkRecipe(kind: "cache", rootID: root.id, folder: folder, backend: kind == .thumbnails ? "thumbnails" : "originals")
        let ticket = TaskCenter.shared.begin("\(title) · \(name)", recipe: recipe, cancel: { [weak self] in self?.stopCacheBuild() })
        cacheBuildTask = Task { await ticket.run {
            var completed = 0, local = 0, failed = 0
            var lastError: String?
            defer { buildingCache = false; cacheBuildTask = nil; TaskCenter.shared.finish(ticket.id, cancelled: Task.isCancelled) }
            if kind == .thumbnails { await refreshAnalysisEdits(ids: Set(selected.map(\.id))) }
            let current = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
            let snapshot = selected.map { current[$0.id] ?? $0 }
            let total = kind == .thumbnails ? snapshot.count : snapshot.reduce(0) { $0 + $1.files.count }
            outer: for asset in snapshot {
                let files = kind == .thumbnails ? [asset.preferred] : asset.files
                for file in files {
                    do { try await ticket.checkpoint() } catch { break outer }
                    cacheBuildStatus = "\(title) · \(name) · \(completed + local + failed + 1)/\(total) · \(file.relativePath)"
                    TaskCenter.shared.update(ticket.id, detail: cacheBuildStatus, completed: completed + local + failed, total: total)
                    let url = URL(fileURLWithPath: root.path, isDirectory: true).appendingPathComponent(file.relativePath, isDirectory: false)
                    do {
                        if kind == .thumbnails {
                            try await ImageCacheService.shared.buildThumbnails(asset: asset, url: url)
                            completed += 1
                        } else {
                            let key = MediaLoader.shared.key(asset: asset, file: file)
                            let result = try await WorkScheduler.shared.run(.copy, control: ticket.control) {
                              await Task.detached(priority: .utility) { () -> Int in
                                if PreviewCache.isLocalOriginal(url), FileManager.default.isReadableFile(atPath: url.path) { return 0 }
                                let cached = PreviewCache.shared.original(url, key: key)
                                defer { PreviewCache.shared.release(cached) }
                                return cached != url ? 1 : -1
                              }.value
                            }
                            if result == 0 { local += 1 }
                            else if result == 1 { completed += 1 }
                            else { throw CatalogError(message: "原片不可用或缓存空间不足") }
                        }
                    } catch is CancellationError { break outer }
                    catch { failed += 1; lastError = error.localizedDescription; TaskCenter.shared.update(ticket.id, failure: file.relativePath + "：" + error.localizedDescription) }
                }
            }
            cacheBuildStatus = "\(Task.isCancelled ? "已停止" : "已完成")\(title) · \(name) · 已缓存/复用 \(completed) · 本地跳过 \(local) · 失败 \(failed)"
            if let lastError { cacheBuildStatus += " · " + lastError }
            TaskCenter.shared.update(ticket.id, detail: cacheBuildStatus, completed: completed + local + failed, total: total)
        } }
    }
    func registerTaskRecovery() {
        TaskCenter.shared.register("cache") { [weak self] recipe in
            guard let self, let root = self.roots.first(where: { $0.id == recipe.rootID }) else { return false }
            guard !self.buildingCache, !self.loading, self.rootsResolved else { self.error = "缓存任务忙碌或图库尚未就绪"; return false }
            self.buildCache(root: root, folder: recipe.folder, kind: recipe.backend == "originals" ? .originals : .thumbnails)
            return true
        }
        TaskCenter.shared.register("export") { [weak self] recipe in
            guard let self, let data = recipe.payload, let plan = try? JSONDecoder().decode(ExportWorkPlan.self, from: data) else { return false }
            if let uncertain = plan.uncertain { self.error = "上次中断时正在导出 " + uncertain.destination.lastPathComponent + "，请检查目标目录。恢复只处理其余文件，避免重复导出。" }
            guard !self.exporting, !plan.remaining.isEmpty else { self.error = "没有可恢复的文件或已有导出任务"; return false }
            self.startExport(plan)
            return true
        }
        TaskCenter.shared.register("scan") { [weak self] recipe in
            guard let self, let root = self.roots.first(where: { $0.id == recipe.rootID }) else { return false }
            guard !self.scanning, !self.loading, !self.rootWritePending else { self.error = "扫描任务忙碌或图库尚未就绪"; return false }
            self.scan(root)
            return true
        }
    }
    @Published var roots: [LibraryRoot] = []
    @Published var assets: [Asset] = [] { didSet { assetRevision += 1 } }
    private var assetRevision = 0
    var contentRevision: Int { assetRevision }
    private var summaryRevision = -1
    @Published private(set) var summary = LibrarySummary()
    @Published var loading = true
    @Published var rootsResolved = false
    @Published var editRevision = 0
    @Published private(set) var checkingAnalysisEdits = false
    @Published private(set) var analysisChangedIDs: Set<String> = []
    private var analysisEditTask: Task<Void, Never>?
    private var analysisEditChecks = 0
    private var analysisEditEpoch: [String: UUID] = [:]
    private var pendingEditIDs: Set<String> = []
    private var pendingAllEdits = false
    func scheduleAnalysisEdits(ids: Set<String>? = nil) {
        if let ids { pendingEditIDs.formUnion(ids) } else { pendingAllEdits = true }
        analysisEditTask?.cancel()
        analysisEditTask = Task {
            do { try await Task.sleep(for: .milliseconds(ids == nil ? 1200 : 0)) } catch { return }
            let ids = pendingAllEdits ? nil : pendingEditIDs
            pendingAllEdits = false; pendingEditIDs = []; analysisEditTask = nil
            await refreshAnalysisEdits(ids: ids)
        }
    }
    func refreshAnalysisEdits(ids: Set<String>? = nil) async {
        guard rootsResolved, !loading else { return }
        analysisEditChecks += 1; checkingAnalysisEdits = true
        defer { analysisEditChecks -= 1; checkingAnalysisEdits = analysisEditChecks > 0 }
        let snapshot = ids.map { ids in assets.filter { ids.contains($0.id) } } ?? assets
        let epoch = UUID()
        for asset in snapshot { analysisEditEpoch[asset.id] = epoch }
        defer { for asset in snapshot where analysisEditEpoch[asset.id] == epoch { analysisEditEpoch.removeValue(forKey: asset.id) } }
        let paths = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0.path) })
        let discovery = Task.detached(priority: .utility) { () -> [Asset] in
            var changes: [Asset] = []
            for var asset in snapshot where !asset.video && !asset.missing {
                if Task.isCancelled { break }
                guard let path = paths[asset.rootID] else { continue }
                let url = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(asset.preferred.relativePath, isDirectory: false)
                do {
                    let token = try PhotoEditStore.analysisRevision(sources: PhotoEditStore.siblings(asset: asset, preferred: url))
                    if token != asset.analysisEditToken { asset.analysisEditToken = token; changes.append(asset) }
                } catch { /* Preserve known versions while originals are offline or sidecars unreadable. */ }
            }
            return changes
        }
        let changes = await withTaskCancellationHandler { await discovery.value } onCancel: { discovery.cancel() }
        guard !Task.isCancelled else { return }
        let starting = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })
        var next = assets, applied: [Asset] = []
        for change in changes {
            guard let i = positions[change.id], analysisEditEpoch[change.id] == epoch, next[i].files == change.files,
                  next[i].analysisEditToken == starting[change.id]?.analysisEditToken else { continue }
            next[i].analysisEditToken = change.analysisEditToken; next[i].analysisTracksEdits = true
            applied.append(next[i]); analysisChangedIDs.insert(change.id)
        }
        if !applied.isEmpty {
            assets = next; rebuild()
            let saved = applied, catalog = catalog
            persist("编辑后的照片等待更新分析") { try catalog.saveAnalysisEdits(saved) }
        }
    }
    @Published var aggregateSimilar = UserDefaults.standard.object(forKey: "aggregateSimilar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(aggregateSimilar, forKey: "aggregateSimilar"); rebuild(); if aggregateSimilar { indexCaptureDates() } }
    }
    @Published var similarityThreshold = min(1.0, max(-1.0, UserDefaults.standard.object(forKey: "similarityThreshold") as? Double ?? 0.98)) {
        didSet {
            let valid = similarityThreshold.isFinite ? min(1, max(-1, similarityThreshold)) : oldValue
            if valid != similarityThreshold { similarityThreshold = valid }
            UserDefaults.standard.set(valid, forKey: "similarityThreshold")
        }
    }
    @Published private(set) var visibleAssets: [Asset] = []
    @Published private(set) var stackMembers: [String: [Asset]] = [:]
    private var stackKeys: [String: String] = [:]
    private var similarityGroups: [String: String] = [:]
    private var similarityFingerprints: [String: String] = [:]
    private var expandedStacks: Set<String> = []
    private var excludedFromStacks: Set<String> = []
    private var stackCovers: Set<String> = []
    private var stackPreferenceKey: String { "similarityPreferences:" + catalog.directory.path }
    func setSimilarityGroups(_ groups: [[String]], snapshot: [Asset]) {
        similarityGroups = [:]
        for members in groups { if let key = members.min() { for id in members { similarityGroups[id] = key } } }
        similarityFingerprints = Dictionary(uniqueKeysWithValues: snapshot.filter { similarityGroups[$0.id] != nil }.map { ($0.id, $0.analysisFingerprint) })
        rebuild()
    }
    private func persistStackPreferences() {
        UserDefaults.standard.set(["excluded": Array(excludedFromStacks), "covers": Array(stackCovers)], forKey: stackPreferenceKey)
    }
    func toggleStack(_ id: String) {
        guard let key = stackKeys[id], let members = stackMembers[id] else { return }
        let visible = Set(visibleAssets.map(\.id))
        if members.filter({ visible.contains($0.id) }).count > 1 {
            expandedStacks.remove(key)
            let cover = members.first { stackCovers.contains($0.id) } ?? members[0]
            if members.contains(where: { $0.id == focusID }) { focusID = cover.id }
            selection.subtract(members.map(\.id)); selection.insert(cover.id)
        } else { expandedStacks.insert(key) }
        rebuild()
    }
    func selectStack(_ id: String) { if let members = stackMembers[id] { selection = Set(members.map(\.id)); focusID = id; expandedStacks.insert(stackKeys[id]!); rebuild() } }
    func excludeFromStack(_ id: String) { excludedFromStacks.insert(id); persistStackPreferences(); rebuild() }
    func restoreToStacks(_ id: String) { excludedFromStacks.remove(id); persistStackPreferences(); rebuild() }
    func isExcludedFromStacks(_ id: String) -> Bool { excludedFromStacks.contains(id) }
    func useAsStackCover(_ id: String) {
        guard let members = stackMembers[id] else { return }
        stackCovers.subtract(members.map(\.id)); stackCovers.insert(id); persistStackPreferences(); rebuild()
    }

    @Published var querying = false
    @Published var pendingWrites = 0
    @Published var gridLimit = 300 { didSet { refreshGridSections() } }
    @Published private(set) var gridSections: [(String, [Asset])] = []
    private var gridDays: [String: String] = [:]
    @Published var rootState: [String: String] = [:]
    private var positions: [String: Int] = [:]
    private var queryTask: Task<Void, Never>?
    private var queryGeneration = UUID()
    private var queryCancellation = CancellationFlag()
    private var prefetchTask: Task<Void, Never>?
    @Published var saveFailed = false
    @Published private(set) var rootWritePending = false
    private var saveGeneration = 0
    @Published var filter = FilterState() { didSet { rebuild() } }
    @Published private(set) var artScores: [String: Double] = [:]
    private var artFingerprints: [String: String] = [:]
    private var artKeyRevision = -1
    private var artKeys: [String: String] = [:]
    private var lastArtSort = Date.distantPast
    var qualitySort: Bool { filter.sort == "qualityHigh" || filter.sort == "qualityLow" }
    var artSort: Bool { filter.sort == "artHigh" || filter.sort == "artLow" || qualitySort }
    func artScore(_ asset: Asset) -> Double? {
        guard !asset.video, artFingerprints[asset.id] == asset.artFingerprint else { return nil }
        return artScores[asset.id]
    }
    func setArtScores(_ scores: [String: Double], fingerprints: [String: String]) {
        artFingerprints = fingerprints; artScores = scores
        if artSort || filter.usesAIScores { rebuild() }
    }
    func setArtScore(_ id: String, raw: Double, fingerprint: String) {
        artFingerprints[id] = fingerprint; artScores[id] = raw
        if (artSort || filter.usesAIScores) && Date().timeIntervalSince(lastArtSort) >= 3 { lastArtSort = Date(); rebuild() }
    }
    @Published private(set) var qualityScores: [String: Double] = [:]
    private var qualityFingerprints: [String: String] = [:]
    func qualityScore(_ asset: Asset) -> Double? {
        guard !asset.video, qualityFingerprints[asset.id] == asset.qualityFingerprint else { return nil }
        return qualityScores[asset.id]
    }
    func setQualityScores(_ scores: [String: Double], fingerprints: [String: String]) {
        qualityFingerprints = fingerprints; qualityScores = scores
        if qualitySort || filter.usesAIScores { rebuild() }
    }
    func setQualityScore(_ id: String, raw: Double, fingerprint: String) {
        qualityFingerprints[id] = fingerprint; qualityScores[id] = raw
        if (qualitySort || filter.usesAIScores) && Date().timeIntervalSince(lastArtSort) >= 3 { lastArtSort = Date(); rebuild() }
    }
    private var ruleEmbeddingScores: [EmbeddingFilterQuery: [String: Double]] = [:]
    private var ruleEmbeddingRevision = -1
    private var ruleEmbeddingScope = ""
    func setRuleEmbeddingScores(_ scores: [EmbeddingFilterQuery: [String: Double]], revision: Int, scope: String) {
        ruleEmbeddingScores = scores; ruleEmbeddingRevision = revision; ruleEmbeddingScope = scope
        rebuild()
    }
    @Published var semanticIDs: [String]? { didSet { rebuild() } }
    @Published var filtered: [Asset] = []
    @Published var selection: Set<String> = []
    @Published var focusID: String?
    @Published var mode = "grid" {
        didSet {
            if mode == "single", oldValue != "single" { viewingNavigation = gridNavigation }
            if mode == "grid", oldValue != "grid" { viewingNavigation = nil; rebuild() }
        }
    }
    @Published var withinPhotoGroup = UserDefaults.standard.bool(forKey: "withinPhotoGroup") {
        didSet { UserDefaults.standard.set(withinPhotoGroup, forKey: "withinPhotoGroup") }
    }
    private var gridNavigation = PhotoNavigationSnapshot()
    private var viewingNavigation: PhotoNavigationSnapshot?
    var photoNavigation: PhotoNavigationSnapshot { viewingNavigation ?? gridNavigation }
    var photoNavigationLabel: String { photoNavigation.label(for: focusID) }
    func canMovePhoto(_ offset: Int, betweenGroups: Bool = false) -> Bool {
        photoNavigation.target(from: focusID, offset: offset, withinGroup: !betweenGroups && withinPhotoGroup) != nil
    }
    func movePhoto(_ offset: Int, betweenGroups: Bool = false) {
        guard let id = photoNavigation.target(from: focusID, offset: offset, withinGroup: !betweenGroups && withinPhotoGroup),
              let index = positions[id] else { return }
        select(assets[index])
    }
    @Published var groupByCaptureDate = UserDefaults.standard.bool(forKey: "groupByCaptureDate") {
        didSet { UserDefaults.standard.set(groupByCaptureDate, forKey: "groupByCaptureDate"); rebuild(); if groupByCaptureDate { indexCaptureDates() } else if !aggregateSimilar { dateCancellation?.cancel(); dateTicket?.control.cancel() } }
    }
    private var dateQueryPending = false
    private var dateTicket: WorkTicket?
    private var dateCancellation: CancellationFlag?
    @Published var indexingDates = false
    @Published var savedFilters: [SavedFilter] = []
    @Published var scanning = false
    @Published var exporting = false
    @Published var status = "添加一个照片或视频目录，开始选片"
    @Published var error: String?
    @Published var exportFailures: [String] = []
    @Published var undoAvailable = false
    @Published var compareIDs: [String] = []
    @Published var pinnedID: String?
    private var undoStack: [[String: Marks]] = []
    private var scanFlag: CancellationFlag?
    private var exportFlag: CancellationFlag?
    private var accessURLs: [URL] = []
    private let scanQueue = DispatchQueue(label: "photolab.scan", qos: .utility)
    private let exportQueue = DispatchQueue(label: "photolab.export", qos: .utility)

    init(catalog: Catalog) {
        self.catalog = catalog
        let preferences = UserDefaults.standard.dictionary(forKey: "similarityPreferences:" + catalog.directory.path)
        excludedFromStacks = Set(preferences?["excluded"] as? [String] ?? [])
        stackCovers = Set(preferences?["covers"] as? [String] ?? [])
        Catalog.work.async {
            do {
                try catalog.prepareIndexes()
                let roots = try catalog.roots(); let assets = try catalog.assets(); let filters = try catalog.filters()
                DispatchQueue.main.async {
                    self.roots = roots; self.assets = assets; self.savedFilters = filters
                    self.positions = Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($0.element.id,$0.offset) })
                    self.loading = false; self.rebuild()
                    self.status = "已载入 \(assets.count) 个拍摄项目"
                    self.resolveRoots()
                    if roots.isEmpty, let index = CommandLine.arguments.firstIndex(of: "--library"), CommandLine.arguments.count > index + 1 {
                        self.addRoot(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                    }
                }
            } catch { DispatchQueue.main.async { self.loading = false; self.error = error.localizedDescription } }
        }
    }
    private func resolveRoots() {
        let snapshot = roots
        Task {
            let resolved = await Task.detached(priority: .utility) {
                snapshot.map { root -> (LibraryRoot, URL?) in
                    var root = root
                    guard let data = root.bookmark else { return (root, nil) }
                    var stale = false
                    if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) {
                        root.path = url.path; return (root, url)
                    }
                    return (root, nil)
                }
            }.value
            for (root,url) in resolved {
                if let url, url.startAccessingSecurityScopedResource() { accessURLs.append(url) }
                if let i = roots.firstIndex(where: { $0.id == root.id }) { roots[i] = root }
            }
            rootsResolved = true
            scheduleAnalysisEdits()
            indexCaptureDates()
        }
    }
    var focused: Asset? { focusID.flatMap { positions[$0] }.map { assets[$0] } }
    var selectedAssets: [Asset] { filtered.filter { selection.contains($0.id) } }
    var allTags: [String] { summary.tags }
    var totalBytes: Int64 { summary.bytes }
    func root(for asset: Asset) -> LibraryRoot? { roots.first { $0.id == asset.rootID } }
    func url(for asset: Asset, file: MediaFile? = nil) -> URL? { root(for: asset).map { URL(fileURLWithPath: $0.path, isDirectory: true).appendingPathComponent((file ?? asset.preferred).relativePath, isDirectory: false) } }
    func folders(for root: LibraryRoot) -> [String] { summary.folders[root.id] ?? [] }
    var lastGridID: String? { visibleAssets.isEmpty ? nil : visibleAssets[min(gridLimit,visibleAssets.count) - 1].id }
    var gridAssets: [Asset] { Array(visibleAssets.prefix(gridLimit)) }
    func revealFocus() {
        if let focusID, let i = visibleAssets.firstIndex(where: { $0.id == focusID }) { gridLimit = max(gridLimit, ((i / 300) + 1) * 300) }
    }
    func loadNextPage() { gridLimit = min(visibleAssets.count, gridLimit + 300) }
    private func refreshGridSections() {
        guard groupByCaptureDate && semanticIDs == nil else { gridSections = [("", gridAssets)]; return }
        let groups = Dictionary(grouping: gridAssets) { gridDays[$0.id] ?? "未知拍摄日期" }
        gridSections = groups.keys.sorted { a, b in
            if a == "未知拍摄日期" { return false }
            if b == "未知拍摄日期" { return true }
            return a > b
        }.map { ($0, groups[$0]!) }
    }
    func rebuild() {
        queryTask?.cancel(); queryCancellation.cancel(); queryCancellation = CancellationFlag()
        let cancel = queryCancellation
        let generation = UUID(); queryGeneration = generation
        querying = true
        let snapshot = assets; let filter = filter; let dates = groupByCaptureDate && semanticIDs == nil; let semantic = semanticIDs
        let art = qualitySort ? qualityScores : artScores; let artPrints = qualitySort ? qualityFingerprints : artFingerprints; let useArt = artSort || filter.usesAIScores
        let ruleArt = artScores, ruleQuality = qualityScores
        let ruleArtPrints = artFingerprints, ruleQualityPrints = qualityFingerprints
        let embeddings = ruleEmbeddingRevision == assetRevision && ruleEmbeddingScope == filter.scopeIdentity ? ruleEmbeddingScores : [:]
        let suffix = qualitySort ? "-q-realign-fe1f45a-iqa-768-v1" : "-q-realign-fe1f45a-iaa-768-v1"
        let cachedKeys = artKeys; let keysCurrent = artKeyRevision == assetRevision
        let revision = assetRevision; let needsSummary = summaryRevision != revision
        let groups = similarityGroups, prints = similarityFingerprints, excluded = excludedFromStacks, covers = stackCovers, expanded = expandedStacks
        let preserve = selection.union([focusID].compactMap { $0 })
        let aggregate = aggregateSimilar && semantic == nil
        queryTask = Task {
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            let result = await Task.detached(priority: .userInitiated) {
                let keys = useArt && !keysCurrent ? Dictionary(uniqueKeysWithValues: snapshot.filter { !$0.video }.map { ($0.id,$0.analysisFingerprint) }) : cachedKeys
                let validArt = useArt ? Dictionary(uniqueKeysWithValues: snapshot.compactMap { a -> (String,Double)? in
                    guard let value = art[a.id], artPrints[a.id] == keys[a.id].map({ $0 + suffix }) else { return nil }
                    return (a.id,value)
                }) : [:]
                var ruleScores = FilterScoreContext(embeddings: embeddings)
                if filter.usesAIScores {
                    for asset in snapshot where !asset.video {
                        guard let key = keys[asset.id] else { continue }
                        if ruleArtPrints[asset.id] == key + "-q-realign-fe1f45a-iaa-768-v1", let raw = ruleArt[asset.id], raw.isFinite { ruleScores.art[asset.id] = (ArtScoring.display(raw) * 100).rounded() / 100 }
                        if ruleQualityPrints[asset.id] == key + "-q-realign-fe1f45a-iqa-768-v1", let raw = ruleQuality[asset.id], raw.isFinite { ruleScores.quality[asset.id] = (ArtScoring.display(raw) * 100).rounded() / 100 }
                    }
                }
                let ordered = LibraryQuery.run(snapshot, filter: filter, dates: dates, semantic: semantic, artScores: validArt, ruleScores: ruleScores, cancelled: { cancel.cancelled })
                let projection = SimilarityProjection.make(ordered, groups: groups, fingerprints: prints, excluded: excluded, covers: covers, expanded: expanded, preserve: preserve, enabled: aggregate)
                let days = dates ? Dictionary(uniqueKeysWithValues: projection.assets.map { ($0.id, CaptureDates.day($0.captureDate)) }) : [:]
                return (ordered, needsSummary && !cancel.cancelled ? LibrarySummary.make(snapshot) : nil, keys, projection, GridNavigation.sections(projection.assets, grouped: dates), days)
            }.value
            guard !Task.isCancelled, queryGeneration == generation else { return }
            if preserve != selection.union([focusID].compactMap { $0 }) { rebuild(); return }
            filtered = result.0
            gridNavigation = result.3.navigation
            visibleAssets = result.3.assets; stackMembers = result.3.members; stackKeys = result.3.keys
            gridRowSections = result.4; gridDays = result.5
            if useArt { artKeys = result.2; artKeyRevision = revision }
            if let value = result.1 { summary = value; summaryRevision = revision }
            let ids = Set((mode == "single" ? assets : filtered).map(\.id)); selection.formIntersection(ids)
            if let focusID, !ids.contains(focusID) { self.focusID = filtered.first?.id }
            gridLimit = min(max(300, gridLimit), max(300, visibleAssets.count)); revealFocus()
            querying = false
            if dateQueryPending { dateQueryPending = false; rebuild() }
        }
    }
    private func applyAssets(_ changed: [Asset], preserveMarks: Bool = false) {
        var next = assets
        for var a in changed {
            if let i = positions[a.id] {
                if preserveMarks { Marks(next[i]).apply(to: &a); if a.files == next[i].files && next[i].captureDateChecked == true { a.captureDate = next[i].captureDate; a.captureDateChecked = true } }
                next[i] = a
            } else { positions[a.id] = next.count; next.append(a) }
        }
        assets = next; rebuild()
    }
    private func persist(_ label: String, recover: Bool = false, work: @escaping () throws -> Void) {
        let ticket = TaskCenter.shared.begin(label, controllable: false)
        pendingWrites += 1; saveGeneration += 1; let generation = saveGeneration
        status = "正在保存…"
        Catalog.work.async {
            let failure: String?
            do { try work(); failure = nil } catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                TaskCenter.shared.finish(ticket.id, error: failure)
                self.pendingWrites -= 1
                if let failure { self.saveFailed = true; self.error = "保存失败，请勿退出：" + failure; self.status = "有标记未保存" }
                else { if recover { self.saveFailed = false }; if generation == self.saveGeneration { self.status = label } }
            }
        }
    }
    func retrySaving() {
        guard !rootWritePending else { return }
        let marks = Dictionary(uniqueKeysWithValues: assets.map { ($0.id,Marks($0)) })
        let snapshot = assets; let roots = roots; let filters = savedFilters; let catalog = catalog
        persist("未保存修改已重新写入", recover:true) {
            try catalog.saveMarks(marks); try catalog.saveDates(snapshot)
            for root in roots { try catalog.save(root:root) }
            try catalog.saveFilters(filters)
        }
    }
    func showCacheSettings() {
        Task {
            let usage = await Task.detached(priority: .utility) { PreviewCache.shared.usage() }.value
            let alert = NSAlert(); alert.messageText = "本地 SSD 缓存"; alert.informativeText = usage + "\n原片、评分、标签和 AI 索引不会被缓存清理删除。"
            let field = NSTextField(string: String(PreviewCache.shared.budgetBytes / 1_000_000_000)); field.frame = NSRect(x: 0,y: 0,width: 200,height: 24)
            alert.accessoryView = field; alert.addButton(withTitle: "保存上限（GB）"); alert.addButton(withTitle: "清理可重建缓存"); alert.addButton(withTitle: "取消")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                guard let gb = Int(field.stringValue), gb >= 1, gb <= 2000 else { error = "请输入 1–2000 GB"; return }
                UserDefaults.standard.set(gb,forKey:"previewCacheGB")
                let ticket = TaskCenter.shared.begin("调整缓存预算 / 清理", priority: 0, controllable: false)
                Task { await Task.detached(priority:.utility) { PreviewCache.shared.trim() }.value; TaskCenter.shared.finish(ticket.id) }
            } else if response == .alertSecondButtonReturn {
                MediaLoader.shared.cache.removeAllObjects()
                let ticket = TaskCenter.shared.begin("清理可重建缓存", controllable: false)
                Task { await ImageCacheService.shared.clearMemory(); MediaLoader.shared.cache.removeAllObjects(); await Task.detached(priority:.utility) { PreviewCache.shared.trim(clear:true) }.value; TaskCenter.shared.finish(ticket.id) }
            }
        }
    }
    func chooseRoot() {
        guard !loading, !rootWritePending else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "原片保留在原目录。数据库和预览缓存在这台 Mac 上。"
        if panel.runModal() == .OK, let url = panel.url { addRoot(url) }
    }
    func addRoot(_ url: URL) {
        guard !loading, !rootWritePending, !scanning, !saveFailed else { return }
        let path = url.standardizedFileURL.path
        if let existing = roots.first(where: { $0.path == path }) { filter.rootID = existing.id; filter.folder = nil; scan(existing); return }
        if let parent = roots.first(where: { DirectoryPaths.relative(path, to: $0.path) != nil }) {
            filter.rootID = parent.id; filter.folder = DirectoryPaths.relative(path, to: parent.path)
            status = "此目录已包含在图库中，已定位到该子目录"; return
        }
        let covered = roots.filter { DirectoryPaths.relative($0.path, to: path) != nil }
        if !covered.isEmpty {
            let alert = NSAlert(); alert.messageText = "扩展到父目录？"
            alert.informativeText = path + "\n\n将合并：" + covered.map(\.name).joined(separator: "、") + "。已有评分、标签、旋转、AI 索引和缓存会保留，不修改原文件。"
            alert.addButton(withTitle: "合并并扫描"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if url.startAccessingSecurityScopedResource() { accessURLs.append(url) }
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        changeDirectory(LibraryRoot(id: UUID().uuidString, path: path, bookmark: bookmark), removing: false)
    }
    func removeRoot(_ root: LibraryRoot) {
        guard !loading, !rootWritePending, !scanning, !saveFailed else { return }
        let alert = NSAlert(); alert.messageText = "从图库移除“\(root.name)”？"
        alert.informativeText = "该目录及子目录将不再显示。不会删除磁盘或 NAS 上的照片和视频；本地评分、标签、旋转和 AI 索引保留，重新添加同一目录时可恢复。"
        alert.addButton(withTitle: "从图库移除"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        changeDirectory(root, removing: true)
    }
    func removeFolder(_ root: LibraryRoot, folder: String) {
        guard !loading, !rootWritePending, !scanning, !saveFailed, !folder.isEmpty else { return }
        let alert = NSAlert(); alert.messageText = "从图库移除“\(folder)”？"
        alert.informativeText = "将移除此子目录及其下级目录的图库记录，不删除磁盘上的文件。评分、标签与 AI 索引保留。如果原目录仍存在，再次扫描时会重新收录。"
        alert.addButton(withTitle: "从图库移除"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let ticket = TaskCenter.shared.begin("移除图库子目录 · " + folder, controllable: false)
        rootWritePending = true; pendingWrites += 1
        let catalog = catalog
        Catalog.work.async {
            do {
                try catalog.removeFolder(rootID: root.id, folder: folder)
                let assets = try catalog.assets()
                DispatchQueue.main.async {
                    self.pendingWrites -= 1; self.rootWritePending = false
                    self.assets = assets
                    self.positions = Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($0.element.id, $0.offset) })
                    let ids = Set(assets.map(\.id)); self.selection.formIntersection(ids)
                    if let focus = self.focusID, !ids.contains(focus) { self.focusID = nil }
                    self.compareIDs = self.compareIDs.filter { ids.contains($0) }
                    if let pinned = self.pinnedID, !ids.contains(pinned) { self.pinnedID = nil }
                    if self.filter.rootID == root.id, let selected = self.filter.folder,
                       selected == folder || selected.hasPrefix(folder + "/") {
                        self.filter.folder = nil; self.mode = "grid"
                    }
                    self.rebuild(); self.status = "子目录已从图库移除；原文件与本地标记保留"
                    TaskCenter.shared.finish(ticket.id)
                }
            } catch { DispatchQueue.main.async {
                self.pendingWrites -= 1; self.rootWritePending = false; self.error = error.localizedDescription
                TaskCenter.shared.finish(ticket.id, error: error.localizedDescription)
            } }
        }
    }
    // Also used by isolated integration tests, without invoking native dialogs.
    func changeDirectory(_ requested: LibraryRoot, removing: Bool) {
        guard !loading, !rootWritePending, !scanning, !saveFailed else { return }
        let ticket = TaskCenter.shared.begin((removing ? "移除图库目录 · " : "合并图库目录 · ") + requested.name, controllable: false)
        rootWritePending = true; pendingWrites += 1; status = removing ? "正在移除目录…" : "正在合并目录并保留已有数据…"
        let catalog = catalog
        Catalog.work.async {
            do {
                var root = requested
                if !removing, let archived = try catalog.allRoots().first(where: { $0.path == requested.path }) { root.id = archived.id }
                try catalog.updateDirectory(root, removing: removing)
                let roots = try catalog.roots(); let assets = try catalog.assets(); let filters = try catalog.filters()
                let updatedRoot = root
                DispatchQueue.main.async {
                    TaskCenter.shared.finish(ticket.id)
                    self.pendingWrites -= 1; self.rootWritePending = false
                    self.roots = roots; self.assets = assets; self.savedFilters = filters
                    self.positions = Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($0.element.id,$0.offset) })
                    let ids = Set(assets.map(\.id)); self.selection.formIntersection(ids)
                    if let focus = self.focusID, !ids.contains(focus) { self.focusID = nil }
                    self.compareIDs = self.compareIDs.filter { ids.contains($0) }
                    if let pinned = self.pinnedID, !ids.contains(pinned) { self.pinnedID = nil }
                    self.mode = "grid"; self.rootState = self.rootState.filter { key,_ in roots.contains { $0.id == key } }
                    self.filter.rootID = removing ? nil : updatedRoot.id; self.filter.folder = nil
                    self.rebuild()
                    self.status = removing ? "目录已从图库移除；原文件与本地标记均保留" : "目录已合并，已有标记和索引已保留"
                    if !removing { self.scan(updatedRoot) }
                }
            } catch { DispatchQueue.main.async { TaskCenter.shared.finish(ticket.id, error: error.localizedDescription); self.pendingWrites -= 1; self.rootWritePending = false; self.error = error.localizedDescription } }
        }
    }
    func relink(_ root: LibraryRoot) {
        guard !scanning, !rootWritePending else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "选择原图库的新位置；相对目录结构应保持一致，评分和标签会保留。"
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.standardizedFileURL.path
            guard !roots.contains(where: { $0.id != root.id && (DirectoryPaths.relative(path, to: $0.path) != nil || DirectoryPaths.relative($0.path, to: path) != nil) }) else {
                error = "该位置与已有目录重叠。请使用添加目录来合并父目录。"; return
            }
            var changed = root; changed.path = path
            changed.bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            if url.startAccessingSecurityScopedResource() { accessURLs.append(url) }
            let updatedRoot = changed; let catalog = catalog
            pendingWrites += 1; rootWritePending = true
            let ticket = TaskCenter.shared.begin("重新关联目录 · " + root.name, controllable: false)
            Catalog.work.async {
                do {
                    try catalog.save(root:updatedRoot)
                    DispatchQueue.main.async { TaskCenter.shared.finish(ticket.id); self.pendingWrites -= 1; self.rootWritePending = false; self.roots = self.roots.map { $0.id == root.id ? updatedRoot : $0 }; self.scan(updatedRoot) }
                } catch { DispatchQueue.main.async { TaskCenter.shared.finish(ticket.id, error: error.localizedDescription); self.pendingWrites -= 1; self.rootWritePending = false; self.error = error.localizedDescription } }
            }
        }
    }
    func restartScan(_ root: LibraryRoot) {
        guard !scanning else { return }
        let catalog = catalog
        Catalog.work.async {
            do {
                try catalog.saveScanState(ScanCheckpoint(rootID:root.id,path:root.path))
                DispatchQueue.main.async { self.scan(root) }
            } catch { DispatchQueue.main.async { self.error = error.localizedDescription } }
        }
    }
    func scan(_ root: LibraryRoot) {
        guard !scanning, !loading, !rootWritePending, roots.contains(where: { $0.id == root.id }) else { return }
        scanning = true; rootState[root.id] = "正在扫描"; status = "扫描 \(root.name)… 已完成目录会分批显示"
        let flag = CancellationFlag(); scanFlag = flag; let catalog = catalog
        let ticket = TaskCenter.shared.begin("扫描 · " + root.name, recipe: WorkRecipe(kind: "scan", rootID: root.id), cancel: { flag.cancel() })
        scanTicket = ticket
        scanQueue.async {
            do {
                var state = try catalog.scanState(root.id) ?? ScanCheckpoint(rootID: root.id, path: root.path)
                if state.complete || state.path != root.path { state = ScanCheckpoint(rootID: root.id, path: root.path) }
                while let folder = state.pending.last {
                    try ticket.control.wait()
                    if flag.cancelled { throw CancellationError() }
                    var listing: ([Asset], [String], Int)?; var lastError: Error?
                    for attempt in 0..<3 {
                        if flag.cancelled { throw CancellationError() }
                        do { listing = try Scanner.directory(root: root, relative: folder, cancelled: { flag.cancelled }); break }
                        catch { lastError = error; if attempt < 2 && !flag.cancelled { Thread.sleep(forTimeInterval: Double(attempt + 1)) } }
                    }
                    guard let (found, children, count) = listing else { throw lastError ?? CatalogError(message: "无法读取目录") }
                    for start in stride(from: 0, to: found.count, by: 500) {
                        if flag.cancelled { throw CancellationError() }
                        let batch = Array(found[start..<min(found.count, start + 500)])
                        let merged = try Catalog.work.sync { try catalog.mergeScan(batch) }
                        DispatchQueue.main.async { self.applyAssets(merged, preserveMarks: true) }
                    }
                    state.pending.removeLast(); state.pending.append(contentsOf: children.reversed()); state.files += count
                    try catalog.saveScanState(state)
                    let savedCount = state.files
                    DispatchQueue.main.async {
                        self.status = "扫描 \(root.name)：已保存 \(savedCount) 个媒体文件 · 可继续浏览"
                        TaskCenter.shared.update(ticket.id, detail: self.status, completed: savedCount)
                    }
                }
                state.complete = true; try catalog.saveScanState(state)
                DispatchQueue.main.async {
                    TaskCenter.shared.finish(ticket.id)
                    self.scanning = false; self.rootState[root.id] = "在线 · 扫描完成"
                    self.status = "\(root.name)：扫描完成。未再次发现的素材保留，避免 NAS 暂时缺失造成误判。"
                    self.indexCaptureDates()
                }
            } catch {
                DispatchQueue.main.async {
                    TaskCenter.shared.finish(ticket.id, error: error is CancellationError ? nil : error.localizedDescription, cancelled: flag.cancelled || ticket.control.cancelled)
                    self.scanning = false; self.rootState[root.id] = flag.cancelled ? "已暂停 · 可续扫" : "不可读 · 可续扫"
                    self.status = "扫描已暂停，已完成目录和原有标记已保存；刷新目录可继续。"
                    if !(error is CancellationError) { self.error = error.localizedDescription }
                }
            }
        }
    }
    func cancelScan() { scanFlag?.cancel(); scanTicket?.control.cancel() }
    func select(_ asset: Asset, modifiers: NSEvent.ModifierFlags = []) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        let selectionOrder = mode == "grid" ? visibleAssets : filtered
        if modifiers.contains(.shift), let focusID, let a = selectionOrder.firstIndex(where: { $0.id == focusID }), let b = selectionOrder.firstIndex(where: { $0.id == asset.id }) {
            selection.formUnion(selectionOrder[min(a,b)...max(a,b)].map(\.id))
        } else if modifiers.contains(.command) {
            if selection.contains(asset.id) { selection.remove(asset.id) } else { selection.insert(asset.id) }
        } else { selection = [asset.id] }
        focusID = asset.id; revealFocus()
        prefetchTask?.cancel()
        if let i = filtered.firstIndex(where: { $0.id == asset.id }) {
            let next = filtered.dropFirst(i + 1).prefix(2).compactMap { a in url(for:a).map { (a,$0) } }
            prefetchTask = Task {
                for (a,url) in next {
                    if Task.isCancelled { break }
                    _ = await MediaLoader.shared.thumbnail(asset:a,url:url)
                }
            }
        }
    }
    var gridColumns = 1
    private var gridRowSections: [Range<Int>] = []
    func moveGridRow(_ direction: Int) {
        guard !visibleAssets.isEmpty else { return }
        guard let current = focusID.flatMap({ id in visibleAssets.firstIndex { $0.id == id } }) else { select(visibleAssets[0]); return }
        let next = GridNavigation.target(current: current, columns: gridColumns, direction: direction, sections: gridRowSections)
        select(visibleAssets[next])
    }
    func move(_ delta: Int) {
        if mode == "single" { movePhoto(delta); return }
        let filtered = mode == "grid" ? visibleAssets : filtered
        guard !filtered.isEmpty else { return }
        let index = focusID.flatMap { id in filtered.firstIndex { $0.id == id } } ?? (delta > 0 ? -1 : filtered.count)
        let asset = filtered[max(0, min(filtered.count - 1, index + delta))]
        select(asset)
        if mode == "compare", let slot = compareIDs.firstIndex(where: { $0 != pinnedID }) { compareIDs[slot] = asset.id }
    }
    func enterSingle() {
        guard let asset = focused ?? selectedAssets.first ?? filtered.first else { return }
        select(asset); mode = "single"
    }
    func returnToGrid() {
        if let asset = focused { select(asset) }
        mode = "grid"; rebuild()
    }
    @discardableResult func rotate(_ id: String, by turns: Int) -> Int? {
        guard !rootWritePending else { return nil }
        guard var asset = assets.first(where: { $0.id == id }), !asset.video else { return nil }
        let previous = Marks(asset)
        asset.rotation = (asset.quarterTurns + turns + 4) % 4
        applyAssets([asset]); undoStack.append([id: previous]); undoAvailable = true
        let changes = [id: Marks(asset)]; let catalog = catalog
        persist("已保存照片旋转方向 · ⌘Z 撤销") { try catalog.saveMarks(changes) }
        return asset.quarterTurns
    }
    func indexCaptureDates() {
        guard groupByCaptureDate || aggregateSimilar, rootsResolved, !indexingDates else { return }
        let snapshot = assets, roots = roots
        let cancel = CancellationFlag(); dateCancellation = cancel
        indexingDates = true
        let ticket = TaskCenter.shared.begin("读取拍摄日期", priority: 0, cancel: { cancel.cancel() })
        dateTicket = ticket
        Task.detached(priority: .utility) { [self] in
            let paths = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0.path) })
            let jobs = snapshot.filter { $0.captureDateChecked != true && paths[$0.rootID] != nil }
            await withTaskGroup(of: (Asset, Double?, Bool).self) { group in
                var next = 0
                func enqueue() {
                    guard !cancel.cancelled, next < jobs.count else { return }
                    let asset = jobs[next]; next += 1
                    let path = paths[asset.rootID]!
                    group.addTask {
                        do { try await ticket.checkpoint() } catch { return (asset, nil, false) }
                        guard !cancel.cancelled else { return (asset, nil, false) }
                        // Prefer the smaller rendered companion before trying RAW metadata.
                        let files = asset.files.sorted { !$0.isRAW && $1.isRAW }
                        let urls = files.map { URL(fileURLWithPath: path).appendingPathComponent($0.relativePath) }
                        let date = await captureDate(for: asset, urls: urls)
                        // A successful read needs no extra NAS permission/stat round trip.
                        let readable = date != nil || urls.contains { FileManager.default.isReadableFile(atPath: $0.path) }
                        return (asset, date, readable)
                    }
                }
                // Bound NAS traffic so browsing can still fetch previews.
                for _ in 0..<4 { enqueue() }
                var changes: [(Asset, Double?)] = []
                var lastFlush = Date(), completed = 0
                for await (asset, date, readable) in group {
                    completed += 1
                    let finishedCount = completed
                    await MainActor.run { TaskCenter.shared.update(ticket.id, detail: asset.name, completed: finishedCount, total: jobs.count) }
                    if readable { changes.append((asset, date)) }
                    let elapsed = Date().timeIntervalSince(lastFlush)
                    if !changes.isEmpty && ((changes.count >= 128 && elapsed >= 2) || elapsed >= 5) {
                        let batch = changes
                        await MainActor.run { self.saveCaptureDates(batch) }
                        changes.removeAll(keepingCapacity: true); lastFlush = Date()
                    }
                    enqueue()
                }
                let batch = changes
                await MainActor.run { self.saveCaptureDates(batch) }
            }
            await MainActor.run {
                TaskCenter.shared.finish(ticket.id, cancelled: cancel.cancelled || ticket.control.cancelled)
                self.indexingDates = false; self.dateCancellation = nil
                if cancel.cancelled && !ticket.control.cancelled && (self.groupByCaptureDate || self.aggregateSimilar) { self.indexCaptureDates() }
            }
        }
    }
    private func saveCaptureDates(_ changes: [(Asset, Double?)]) {
        let values = Dictionary(uniqueKeysWithValues: changes.map { ($0.0.id, $0) })
        let updated = values.values.compactMap { old, date -> Asset? in
            guard let index = positions[old.id] else { return nil }
            var current = assets[index]
            guard old.files == current.files else { return nil }
            current.captureDate = date; current.captureDateChecked = true
            return current
        }
        guard !updated.isEmpty else { return }
        let summaryCurrent = summaryRevision == assetRevision
        let artKeysCurrent = artKeyRevision == assetRevision
        var next = assets
        for asset in updated { if let index = positions[asset.id] { next[index] = asset } }
        assets = next
        // Date metadata does not change folder/tag totals or analysis fingerprints.
        if summaryCurrent { summaryRevision = assetRevision }
        if artKeysCurrent { artKeyRevision = assetRevision }
        // Let a large in-flight sort finish instead of repeatedly cancelling it.
        if querying { dateQueryPending = true } else { rebuild() }
        let catalog = catalog
        persist("拍摄时间已保存") { try catalog.saveDates(updated) }
    }
    func compare() {
        let chosen = selectedAssets
        guard chosen.count >= 2 else { error = "按住 ⌘ 选择 2–4 个项目再对比（视频最多两段）。"; return }
        guard chosen.count <= 4 && chosen.filter(\.video).count <= 2 else { error = "一次最多对比 4 个项目，其中视频最多两段。"; return }
        compareIDs = chosen.map(\.id); mode = "compare"
    }
    func mark(assetID: String? = nil, rating: Int? = nil, flag: Int? = nil, addTags: [String] = [], removeTag: String? = nil) {
        guard !rootWritePending else { return }
        let ids = assetID.map { Set([$0]) } ?? (selection.isEmpty ? Set([focusID].compactMap { $0 }) : selection)
        guard !ids.isEmpty else { return }
        let targets = assets.filter { ids.contains($0.id) }
        let undo = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, Marks($0)) })
        let changed = targets.map { item -> Asset in
            var item = item
            if let rating { item.rating = rating }
            if let flag { item.flag = flag }
            item.tags = Array(Set(item.tags + addTags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
            if let removeTag { item.tags.removeAll { $0 == removeTag } }
            return item
        }
        applyAssets(changed)
        undoStack.append(undo); if undoStack.count > 100 { undoStack.removeFirst() }; undoAvailable = true
        let marks = Dictionary(uniqueKeysWithValues: changed.map { ($0.id, Marks($0)) }); let catalog = catalog
        persist("已保存 \(changed.count) 个项目的标记 · ⌘Z 撤销") { try catalog.saveMarks(marks) }
    }
    func undo() {
        guard !rootWritePending else { return }
        guard let previous = undoStack.last else { return }
        let changed = assets.filter { previous[$0.id] != nil }.map { asset -> Asset in var asset = asset; previous[asset.id]?.apply(to: &asset); return asset }
        applyAssets(changed); undoStack.removeLast(); undoAvailable = !undoStack.isEmpty
        let catalog = catalog
        persist("已撤销上一次标记") { try catalog.saveMarks(previous) }
    }
    func saveFilter(name: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let result = savedFilters + [SavedFilter(name: name, state: filter)]
        savedFilters = result; let catalog = catalog
        persist("筛选器已保存") { try catalog.saveFilters(result) }
    }
    func deleteFilter(_ id: String) {
        let result = savedFilters.filter { $0.id != id }
        savedFilters = result; let catalog = catalog
        persist("筛选器已保存") { try catalog.saveFilters(result) }
    }
    func export(assets chosen: [Asset], mode: ExportMode, options: PhotoExportOptions = PhotoExportOptions()) {
        guard !exporting else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = "选择导出目录。保留子目录结构；同名文件另存，不覆盖；视频只复制原片。"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        if roots.contains(where: { destination.path == $0.path || destination.path.hasPrefix($0.path + "/") }) { error = "请把导出目录选在图库之外，避免再次扫描到导出副本。"; return }
        let jobs = chosen.flatMap { asset -> [ExportWorkFile] in
            guard let root = root(for: asset) else { return [] }
            if mode == .edited && !asset.video {
                let urls = asset.files.map { URL(fileURLWithPath: root.path, isDirectory: true).appendingPathComponent($0.relativePath, isDirectory: false) }
                let target = Exporter.destination(base: destination, root: root, file: asset.preferred).deletingPathExtension().appendingPathExtension("edited." + options.format.fileExtension)
                return [ExportWorkFile(sources: urls, destination: target, edited: true, rotation: asset.quarterTurns, options: options)]
            }
            return Exporter.files(asset, mode: mode).map { file in
                ExportWorkFile(sources: [URL(fileURLWithPath: root.path, isDirectory: true).appendingPathComponent(file.relativePath, isDirectory: false)], destination: Exporter.destination(base: destination, root: root, file: file), edited: false, rotation: 0)
            }
        }
        startExport(ExportWorkPlan(destination: destination, remaining: jobs))
    }
    func startExport(_ plan: ExportWorkPlan) {
        guard !exporting else { error = "已有导出任务，请先完成或取消"; return }
        guard !plan.remaining.isEmpty else { error = "没有剩余可导出的文件"; return }
        exporting = true; exportFailures = []
        let flag = CancellationFlag(); exportFlag = flag
        let ticket = TaskCenter.shared.begin("导出 · " + plan.destination.lastPathComponent, total: plan.remaining.count, cancel: { flag.cancel() })
        exportTicket = ticket
        Task { await ticket.run {
            let access = plan.destination.startAccessingSecurityScopedResource()
            defer { if access { plan.destination.stopAccessingSecurityScopedResource() }; exporting = false; TaskCenter.shared.finish(ticket.id, cancelled: flag.cancelled || ticket.control.cancelled) }
            var remaining = plan.remaining, failed: [ExportWorkFile] = [], count = 0
            func save(_ uncertain: ExportWorkFile? = nil) async throws {
                let payload = try JSONEncoder().encode(ExportWorkPlan(destination: plan.destination, remaining: failed + remaining, uncertain: uncertain))
                try await TaskCenter.shared.checkpointRecipe(ticket.id, WorkRecipe(kind: "export", payload: payload))
            }
            do {
                try await save()
                while !remaining.isEmpty {
                    try await ticket.checkpoint()
                    if flag.cancelled { break }
                    let job = remaining.removeFirst()
                    // Persist before writing. On a crash this one file needs inspection,
                    // rather than blindly exporting another copy on recovery.
                    try await save(job)
                    do {
                        _ = try await WorkScheduler.shared.run(.copy, control: ticket.control) {
                            try await Task.detached(priority: .utility) {
                                try autoreleasepool {
                                    if job.edited {
                                        let source = PhotoEditStore.preferredSource(job.sources) ?? job.sources[0]
                                        return try PhotoEditStore.export(source, to: job.destination, rotation: job.rotation, options: job.options ?? PhotoExportOptions(format: .tiff))
                                    }
                                    return try Exporter.copy(source: job.sources[0], destination: job.destination)
                                }
                            }.value
                        }
                    } catch {
                        failed.append(job)
                        if !(error is CancellationError) {
                            let message = job.destination.lastPathComponent + "：" + error.localizedDescription
                            exportFailures.append(message); TaskCenter.shared.update(ticket.id, failure: message)
                        }
                    }
                    count += 1
                    status = "导出 \(count)/\(plan.remaining.count) · 失败 \(failed.count)"
                    TaskCenter.shared.update(ticket.id, detail: status, completed: count)
                    try await save()
                }
            } catch {
                if !(error is CancellationError) { TaskCenter.shared.update(ticket.id, failure: "无法保存导出进度：" + error.localizedDescription) }
            }
        } }
    }
    func cancelExport() { exportFlag?.cancel(); exportTicket?.control.cancel() }
}
