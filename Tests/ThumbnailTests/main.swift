import AppKit
import CoreImage
import ImageIO
import CryptoKit

@main struct ThumbnailTests {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw CatalogError(message: message) }
    }
    static func width(_ image: NSImage?) -> Int { Int(image?.size.width ?? 0) }
    static func main() async {
        do { try await run(); print("PASS thumbnail tiers, disk reuse, offline fallback, edited previews") }
        catch { print("FAIL: \(error)"); exit(1) }
    }
    @MainActor static func run() async throws {
        try check(ThumbnailResolution.tier(for: 240, scale: 2) == 480, "small Retina tier")
        try check(ThumbnailResolution.tier(for: 241, scale: 2) == 960, "medium Retina tier")
        try check(ThumbnailResolution.tier(for: 600, scale: 2) == 1440, "large Retina tier")
        try check(ThumbnailResolution.tier(for: 600, scale: 1) == 960, "standard display tier")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("test.jpg")
        let rendered = CIImage(color: CIColor(red: 0.3, green: 0.6, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 1800, height: 1200))
        try PhotoEditStore.encode(PhotoEditStore.cgImage(rendered), to: source, tiff: false)
        var asset = Asset(id: UUID().uuidString, rootID: "test", folder: "", name: "test", video: false, files: [MediaFile(relativePath: "test.jpg", size: 1, modified: 1)], date: 1)
        let legacyEntries = asset.files.map { "\(asset.identityPath($0))|\($0.size)|\($0.modified)" }.joined(separator: "\n")
        let legacyFingerprint = SHA256.hash(data: Data("\(asset.id)|\(legacyEntries)|0|imageio-sdr-srgb-512-rotation-v1".utf8)).map { String(format: "%02x", $0) }.joined()
        try check(asset.analysisFingerprint == legacyFingerprint, "upgrade invalidated legacy model results")
        let loader = MediaLoader.shared
        for size in [480, 960, 1440] {
            let result = await loader.thumbnail(asset: asset, url: source, maxDimension: size)
            try check(width(result.image) == size, "wrong generated size \(size)")
        }
        // A foreground request for the SAME image must not join work stuck in
        // the background decode lane. The watchdog releases it on regression.
        var queuedAsset = asset; queuedAsset.id = UUID().uuidString
        let occupied = WorkControl(priority: 0)
        try await WorkScheduler.shared.acquire(.decode, control: occupied)
        let backgroundDestination = folder.appendingPathComponent("background.jpg")
        let background = Task { try await ImageCacheService.shared.analysis(asset: queuedAsset, url: source, destination: backgroundDestination) }
        let queuedDeadline = Date().addingTimeInterval(5)
        while await WorkScheduler.shared.queuedCount() == 0 && Date() < queuedDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let wasQueued = await WorkScheduler.shared.queuedCount() > 0
        let watchdog = Task.detached {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            await WorkScheduler.shared.release(.decode)
        }
        let start = Date()
        let interactive = await loader.thumbnail(asset: queuedAsset, url: source, maxDimension: 960)
        let elapsed = Date().timeIntervalSince(start)
        watchdog.cancel()
        await WorkScheduler.shared.release(.decode)
        try await background.value
        try check(wasQueued && width(interactive.image) == 960 && elapsed < 4, "foreground waited for background generation of same image")

        // A corrupt sidecar must not be consulted on an existing grid cache hit.
        let sidecar = PhotoEditStore.sidecar(source)
        try Data("invalid sidecar".utf8).write(to: sidecar)
        await ImageCacheService.shared.clearMemory()
        let fastHit = await loader.thumbnail(asset: asset, url: source, maxDimension: 960)
        try check(width(fastHit.image) == 960, "cache hit probed invalid sidecar")
        try FileManager.default.removeItem(at: sidecar)
        loader.cache.removeAllObjects()
        await ImageCacheService.shared.clearMemory()
        try FileManager.default.removeItem(at: source)
        let cached = await loader.thumbnail(asset: asset, url: source, maxDimension: 1440)
        try check(width(cached.image) == 1440, "high resolution disk reuse")
        loader.cache.removeAllObjects()
        await ImageCacheService.shared.clearMemory()
        let base = loader.key(asset: asset, file: asset.preferred)
        _ = base
        for size in [960, 1440] {
            try FileManager.default.removeItem(at: PreviewCache.shared.root.appendingPathComponent("Images/" + ImageCacheService.key(asset: asset, dimension: size) + ".jpg"))
        }
        let fallback = await loader.thumbnail(asset: asset, url: source, maxDimension: 1440)
        try check(width(fallback.image) == 480, "offline fallback lost existing thumbnail")
        try PhotoEditStore.encode(PhotoEditStore.cgImage(rendered), to: source, tiff: false)
        let legacy = asset.analysisFingerprint
        let destination = folder.appendingPathComponent("analysis.jpg")
        try await ImageCacheService.shared.analysis(asset: asset, url: source, destination: destination)
        let analysis = try Data(contentsOf: destination)
        let grid = try await ImageCacheService.shared.data(asset: asset, url: source, dimension: 960)
        try check(analysis == grid && width(NSImage(data: analysis)) == 960, "models and grid did not share 960 bytes")
        var doc = PhotoEditDocument(source: try EditSource.read(source))
        doc.adjustments.cropWidth = 0.5

        _ = try PhotoEditStore.save(doc, source: source, expectedToken: nil, cache: true)
        var rejectedStaleInput = false
        do { try await ImageCacheService.shared.analysis(asset: asset, url: source, destination: destination) }
        catch { rejectedStaleInput = true }
        try check(rejectedStaleInput, "model input reused cached image after edit without validating revision")
        asset.analysisEditToken = try PhotoEditStore.analysisRevision(sources: [source])
        try check(asset.analysisFingerprint != legacy, "edit did not invalidate model fingerprints")
        try await ImageCacheService.shared.analysis(asset: asset, url: source, destination: destination)
        let edited = NSImage(contentsOf: destination)!
        try await ImageCacheService.shared.buildThumbnails(asset: asset, url: source)
        for (dimension, expectedWidth, expectedHeight) in [(2560,900,1200),(1440,900,1200),(960,720,960),(480,360,480)] {
            let bytes = PreviewCache.shared.imageData(key: ImageCacheService.key(asset: asset, dimension: dimension))!
            let cachedImage = NSImage(data: bytes)!
            try check(Int(cachedImage.size.width) == expectedWidth && Int(cachedImage.size.height) == expectedHeight, "edited pyramid lost crop or upscaled original")
        }
        try check(Int(edited.size.height) == 960 && Int(edited.size.width) == 720, "analysis ignored edited crop")
        try check(try Data(contentsOf: destination) != analysis, "edited analysis reused original")
        for size in [480, 960, 1440] {
            let preview = try PhotoEditStore.preview(source, thumbnail: true, maxDimension: size)
            try check(Int(max(preview!.size.width, preview!.size.height)) == min(size, 1200), "edited preview reused small embedded JPEG at \(size)")
        }
        let full = try PhotoEditStore.preview(source, thumbnail: false)
        try check(width(full) == 900, "full edited preview changed")
        let catalog = try Catalog(directory: folder.appendingPathComponent("catalog"))
        asset.analysisTracksEdits = true
        try catalog.save(assets: [asset])
        asset.analysisEditToken = nil
        try catalog.saveAnalysisEdits([asset])
        let reopened = try Catalog(directory: catalog.directory).asset(asset.id)!
        try check(reopened.analysisTracksEdits == true && reopened.analysisEditToken == nil, "reset lost refresh eligibility on restart")
        let previous = try PhotoEditStore.read(source)!
        var reset = previous.document; reset.adjustments = PhotoAdjustments()
        _ = try PhotoEditStore.commit(reset, source: source, expectedToken: previous.token, cache: false)
        try check(try PhotoEditStore.analysisRevision(sources: [source]) == nil, "reset kept edited revision")
        try await ImageCacheService.shared.analysis(asset: asset, url: source, destination: destination)
        try check(try Data(contentsOf: destination) == analysis, "reset did not recover original cache")
        try catalog.save(root: LibraryRoot(id: "test", path: folder.path))
        let library = LibraryModel(catalog: catalog)
        let deadline = Date().addingTimeInterval(15)
        while library.loading || !library.rootsResolved {
            if Date() > deadline { throw CatalogError(message: "library initialization timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
        library.setArtScores([asset.id: 0.5], fingerprints: [asset.id: asset.artFingerprint])
        try check(library.artScore(library.assets[0]) != nil, "legacy score hidden before edit")
        var changedDoc = PhotoEditDocument(source: try EditSource.read(source)); changedDoc.adjustments.exposure = 0.5
        _ = try PhotoEditStore.save(changedDoc, source: source, expectedToken: nil, cache: false)
        await library.refreshAnalysisEdits(ids: [asset.id])
        try check(library.assets[0].analysisEditToken != nil && library.assets[0].analysisTracksEdits == true, "library did not detect edit")
        try check(library.artScore(library.assets[0]) == nil && library.analysisChangedIDs.contains(asset.id), "edited score was not invalidated")
        let editedEnvelope = try PhotoEditStore.read(source)!
        var neutralDoc = editedEnvelope.document; neutralDoc.adjustments = PhotoAdjustments()
        _ = try PhotoEditStore.commit(neutralDoc, source: source, expectedToken: editedEnvelope.token, cache: false)
        await library.refreshAnalysisEdits(ids: [asset.id])
        try check(library.assets[0].analysisEditToken == nil && library.assets[0].analysisTracksEdits == true, "library reset lost refresh eligibility")

        // Local originals must never be duplicated, even if an old cache exists.
        try check(PreviewCache.isLocalOriginal(source), "local volume not identified")
        let originalKey = loader.key(asset: asset, file: asset.preferred)
        let originalPath = PreviewCache.shared.root.appendingPathComponent("Originals/" + originalKey + ".jpg")
        try check(PreviewCache.shared.original(source, key: originalKey) == source, "local original copied")
        try check(!FileManager.default.fileExists(atPath: originalPath.path), "local original cache created")
        try Data(contentsOf: source).write(to: originalPath)
        try check(PreviewCache.shared.original(source, key: originalKey) == source, "local original ignored in favor of redundant cache")
        try FileManager.default.removeItem(at: originalPath)

        // Folder selection includes descendants, not similarly named siblings.
        var target = asset; target.id = UUID().uuidString; target.folder = "set/child"
        target.files = [MediaFile(relativePath: "test.jpg", size: 1, modified: 1)]
        var outside = target; outside.id = UUID().uuidString; outside.folder = "set-other"
        library.assets = [target, outside]
        let root = LibraryRoot(id: "test", path: folder.path)
        library.buildCache(root: root, folder: "set", kind: .thumbnails)
        let buildDeadline = Date().addingTimeInterval(30)
        while library.buildingCache {
            if Date() > buildDeadline { library.stopCacheBuild(); throw CatalogError(message: "cache build timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
        try check(library.cacheBuildStatus.contains("失败 0"), "bulk build failed: " + library.cacheBuildStatus)
        for dimension in [480, 960, 1440, 2560] {
            try check(PreviewCache.shared.imageData(key: ImageCacheService.key(asset: target, dimension: dimension)) != nil, "bulk tier missing")
            try check(PreviewCache.shared.imageData(key: ImageCacheService.key(asset: outside, dimension: dimension)) == nil, "bulk build escaped selected folder")
        }
        // With only the 2560 tier remaining, a fully offline source must still
        // produce every smaller tier. Derivation must not reopen the source.
        let largestKey = ImageCacheService.key(asset: target, dimension: 2560)
        let largestBytes = PreviewCache.shared.imageData(key: largestKey)!
        let backup = folder.appendingPathComponent("saved-source.jpg")
        try FileManager.default.moveItem(at: source, to: backup)
        for dimension in [1440, 960, 480] {
            try FileManager.default.removeItem(at: PreviewCache.shared.root.appendingPathComponent("Images/" + ImageCacheService.key(asset: target, dimension: dimension) + ".jpg"))
        }
        await ImageCacheService.shared.clearMemory()
        try await ImageCacheService.shared.buildThumbnails(asset: target, url: source)
        for dimension in [1440, 960, 480] {
            let bytes = PreviewCache.shared.imageData(key: ImageCacheService.key(asset: target, dimension: dimension))!
            try check(width(NSImage(data: bytes)) == dimension, "offline pyramid has wrong size")
        }
        try check(PreviewCache.shared.imageData(key: largestKey) == largestBytes, "valid largest cache rewritten")
        let smallKey = ImageCacheService.key(asset: target, dimension: 480)
        let smallBytes = PreviewCache.shared.imageData(key: smallKey)!
        try await ImageCacheService.shared.buildThumbnails(asset: target, url: source)
        try check(PreviewCache.shared.imageData(key: smallKey) == smallBytes, "repeat build rewrote existing tier")
        try FileManager.default.moveItem(at: backup, to: source)

        library.buildCache(root: root, folder: "set", kind: .originals)
        while library.buildingCache { try await Task.sleep(for: .milliseconds(20)) }
        try check(library.cacheBuildStatus.contains("本地跳过 1") && library.cacheBuildStatus.contains("失败 0"), "bulk local skip failed")
        library.buildCache(root: root, kind: .thumbnails)
        library.stopCacheBuild()
        while library.buildingCache { try await Task.sleep(for: .milliseconds(20)) }
        try check(library.cacheBuildStatus.hasPrefix("已停止"), "bulk cancellation lost")

        // Export retry preserves successful outputs and retries only failures.
        let output = folder.appendingPathComponent("export")
        let missingSource = folder.appendingPathComponent("later.jpg")
        let jobs = [ExportWorkFile(sources: [source], destination: output.appendingPathComponent("first.jpg"), edited: false, rotation: 0),
                    ExportWorkFile(sources: [missingSource], destination: output.appendingPathComponent("later.jpg"), edited: false, rotation: 0)]
        library.startExport(ExportWorkPlan(destination: output, remaining: jobs))
        while library.exporting { try await Task.sleep(for: .milliseconds(20)) }
        let exportRecord = TaskCenter.shared.records.first { $0.recipe?.kind == "export" }!
        try check(exportRecord.state == .failed, "partial export failure missing from task center")
        let remaining = try JSONDecoder().decode(ExportWorkPlan.self, from: exportRecord.recipe!.payload!)
        try check(remaining.remaining.count == 1 && remaining.uncertain == nil, "export checkpoint included successful file")
        try FileManager.default.copyItem(at: source, to: missingSource)
        library.registerTaskRecovery()
        TaskCenter.shared.retry(exportRecord)
        while library.exporting { try await Task.sleep(for: .milliseconds(20)) }
        let exported = try FileManager.default.contentsOfDirectory(atPath: output.path)
        try check(Set(exported) == Set(["first.jpg", "later.jpg"]), "retry duplicated successful exports")

    }
}
