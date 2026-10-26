import Foundation
import AppKit

@main struct SimilarityIntegration {
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(90)
        while !ready() {
            if Date() > deadline { throw CatalogError(message: "similarity integration timed out") }
            try await Task.sleep(for: .milliseconds(30))
        }
    }
    static func check(_ value: Bool, _ message: String) throws { if !value { throw CatalogError(message: message) } }
    @MainActor static func main() async {
        do { try await run() }
        catch { print("FAIL: \(error)"); fflush(stdout); exit(1) }
    }
    @MainActor static func run() async throws {
        _ = NSApplication.shared
        print("Starting real SigLIP integration"); fflush(stdout)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("photolab-auto-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let media = temp.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        for name in ["a.jpg", "b.jpg"] { try FileManager.default.copyItem(at: source, to: media.appendingPathComponent(name)) }
        let root = LibraryRoot(id: "test", path: media.path)
        let catalog = try Catalog(directory: temp.appendingPathComponent("catalog"))
        try catalog.save(root: root)
        let (scanned, _, _) = try Scanner.directory(root: root, relative: "", cancelled: { false })
        try catalog.save(assets: scanned)
        let library = LibraryModel(catalog: catalog)
        let savedAggregation = library.aggregateSimilar, savedThreshold = library.similarityThreshold
        defer { library.aggregateSimilar = savedAggregation; library.similarityThreshold = savedThreshold }
        library.aggregateSimilar = true
        library.similarityThreshold = 0.98
        try await wait { !library.loading && library.rootsResolved && !library.indexingDates && !library.querying }
        print("Library ready: \(library.assets.count), dates \(library.assets.compactMap(\.captureDate))"); fflush(stdout)
        let engine = SemanticSearchModel(backend: "siglip")
        await engine.automaticallyIndex(library)
        try await wait { !engine.busy && !library.indexingDates && !library.querying }
        await engine.automaticallyIndex(library)
        try await wait { !engine.busy && !library.querying }
        print("Indexed: \(engine.message), error: \(engine.error ?? "none")"); fflush(stdout)
        try check(engine.error == nil && engine.fingerprints.count == 2, "automatic initial index: \(engine.error ?? "missing vectors")")
        try check(library.visibleAssets.count == 1 && library.filtered.count == 2, "automatic aggregation or complete filter scope failed")
        engine.cancel()
        library.similarityThreshold = 0.90
        await engine.automaticallyIndex(library)
        try await wait { !engine.busy && !library.querying }
        try check(library.visibleAssets.count == 1 && engine.fingerprints.count == 2 && engine.autoPaused, "threshold update resumed inference or lost groups")
        library.similarityThreshold = 0.98
        await engine.automaticallyIndex(library)
        try await wait { !engine.busy && !library.querying }
        let cover = library.visibleAssets[0].id
        library.toggleStack(cover)
        try await wait { !library.querying }
        try check(library.visibleAssets.count == 2, "expand failed")
        library.toggleStack(cover)
        try await wait { !library.querying }
        library.move(1)
        try check(library.focusID == cover, "collapsed navigation entered hidden member")
        let first = library.assets[0]
        library.excludeFromStack(first.id)
        try await wait { !library.querying }
        try check(library.visibleAssets.count == 2, "manual exclusion failed")
        library.restoreToStacks(first.id)
        library.selection = []; library.focusID = nil; library.rebuild()
        try await wait { !library.querying }
        engine.cancel()
        try FileManager.default.copyItem(at: source, to: media.appendingPathComponent("c.jpg"))
        library.scan(root)
        try await wait { !library.scanning && !library.indexingDates && !library.querying }
        await engine.automaticallyIndex(library)
        try check(!engine.busy && engine.fingerprints.count == 2, "paused index restarted on import")
        engine.resumeAutomatic(library)
        try await wait { engine.fingerprints.count == 3 && !engine.busy && !library.querying }
        try check(library.visibleAssets.count == 1 && library.filtered.count == 3, "incremental import did not aggregate")
        let restarted = SemanticSearchModel(backend: "siglip")
        await restarted.automaticallyIndex(library)
        try await wait { !restarted.busy && !library.querying }
        try check(restarted.message.contains("新建 0") && restarted.fingerprints.count == 3, "restart reran inference")
        library.semanticIDs = library.filtered.map(\.id)
        try await wait { !library.querying }
        try check(library.visibleAssets.count == 3, "semantic results remained collapsed")
        library.semanticIDs = nil
        library.selection = []; library.focusID = nil
        let ordered = library.assets.sorted { $0.name < $1.name }
        let a = ordered[0], b = ordered[1], c = ordered[2]
        library.setSimilarityGroups([[a.id, b.id]], snapshot: library.assets)
        let prints = Dictionary(uniqueKeysWithValues: library.assets.map { ($0.id, $0.artFingerprint) })
        library.setArtScores([a.id: 4.8, b.id: 3.6, c.id: 4.5], fingerprints: prints)
        library.filter.sort = "artHigh"
        try await wait { !library.querying }
        try check(library.visibleAssets.map(\.id) == [a.id, c.id], "groups not ranked by maximum")
        let savedMode = library.withinPhotoGroup
        defer { library.withinPhotoGroup = savedMode }
        library.select(a); library.enterSingle()
        library.withinPhotoGroup = true; library.move(1)
        try check(library.focusID == b.id, "single viewer did not enter second member")
        library.move(1)
        try check(library.focusID == b.id, "single viewer crossed group boundary")
        library.withinPhotoGroup = false
        try check(library.focusID == b.id, "mode toggle jumped photo")
        library.move(1)
        try check(library.focusID == c.id, "single viewer did not navigate between groups")
        library.setArtScores([a.id: 1, b.id: 2, c.id: 5], fingerprints: prints)
        try await wait { !library.querying }
        library.move(-1)
        try check(library.focusID == a.id, "score update reordered active viewing session")
        library.returnToGrid()
        try await wait { !library.querying }
        try check(library.photoNavigation.covers == [c.id, b.id], "returning to grid did not apply new score order")
        print("PASS model viewer: score-ranked groups, both navigation modes, no mode-toggle jump, frozen session, refresh on return")
        print("PASS real SigLIP: automatic index, grouping, grid navigation, manual exclusion, import while paused, resume, restart reuse, semantic results")
    }
}
