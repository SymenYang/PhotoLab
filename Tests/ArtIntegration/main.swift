import Foundation
import AppKit

@main struct ArtIntegration {
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(60)
        while !condition() {
            if Date() > deadline { throw CatalogError(message: "integration timeout") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    @MainActor static func main() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("photolab-art-integration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let media = dir.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        for i in 0..<6 { try FileManager.default.copyItem(at: input, to: media.appendingPathComponent("image\(i).jpg")) }
        let root = LibraryRoot(id: UUID().uuidString, path: media.path)
        let catalog = try Catalog(directory: dir.appendingPathComponent("catalog"))
        try catalog.prepareIndexes(); try catalog.save(root: root)
        let (assets,_,_) = try Scanner.directory(root: root, relative: "", cancelled: { false })
        _ = try catalog.mergeScan(assets)
        let library = LibraryModel(catalog: catalog)
        try await wait { !library.loading && !library.querying }
        let first = SemanticSearchModel(backend: "art")
        let scoped = Array(library.assets.prefix(4))
        first.index(library, photos: scoped, scopeName: "test")
        try await wait { first.rawScores.count >= 1 || !first.indexing }
        precondition(first.error == nil, first.error ?? "")
        first.cancel()
        try await wait { !first.indexing }
        precondition(first.rawScores.count >= 1 && first.rawScores.count < 4, "pause must stop before remaining work")
        let paused = first.rawScores.count
        let resumed = SemanticSearchModel(backend: "art")
        await resumed.refresh(library)
        precondition(resumed.rawScores.count == paused)
        resumed.index(library, photos: scoped, scopeName: "test")
        try await wait { !resumed.indexing }
        precondition(resumed.error == nil, resumed.error ?? "")
        precondition(resumed.rawScores.count == 4 && library.artScore(scoped[0]) != nil)
        precondition(library.assets.filter { library.artScore($0) != nil }.count == 4, "scope must exclude other photos")
        var rotated = scoped[0];rotated.rotation=1
        precondition(library.artScore(rotated) == nil, "rotated photo must not display stale score")
        var bad = scoped[0];bad.id=UUID().uuidString;bad.files[0].relativePath="missing.jpg"
        resumed.index(library, photos: [bad], scopeName: "missing")
        try await wait { !resumed.indexing }
        precondition(resumed.failedIDs.contains(bad.id))
        let restored = SemanticSearchModel(backend: "art")
        await restored.refresh(library)
        precondition(restored.failedIDs.contains(bad.id), "failure survives restart")
        try FileManager.default.copyItem(at: input, to: media.appendingPathComponent("missing.jpg"))
        restored.index(library, photos: [bad], scopeName: "retry", retryOnly: true)
        try await wait { !restored.indexing }
        precondition(restored.error == nil && !restored.failedIDs.contains(bad.id) && restored.rawScores[bad.id] != nil)
        let savedArt = library.artScore(scoped[0])
        let quality = SemanticSearchModel(backend: "quality")
        await quality.refresh(library)
        precondition(quality.rawScores.isEmpty && library.qualityScore(scoped[0]) == nil)
        quality.index(library, photos: [scoped[0]], scopeName: "quality")
        try await wait { !quality.indexing }
        precondition(quality.error == nil, quality.error ?? "")
        precondition(library.qualityScore(scoped[0]) != nil && library.artScore(scoped[0]) == savedArt)
        precondition(library.qualityScore(rotated) == nil)
        let qualityRestart = SemanticSearchModel(backend: "quality")
        await qualityRestart.refresh(library)
        precondition(qualityRestart.rawScores == quality.rawScores)
        library.filter.sort = "qualityHigh"
        try await wait { !library.querying }
        precondition(library.filtered.first?.id == scoped[0].id)
        // Queue multiple scopes on one controller and across scoring backends.
        var a = scoped[0]; a.id = UUID().uuidString
        var b = scoped[1]; b.id = UUID().uuidString
        let queuedArt = SemanticSearchModel(backend: "art")
        let queuedQuality = SemanticSearchModel(backend: "quality")
        queuedArt.index(library, photos: [a], scopeName: "queue-a")
        queuedQuality.index(library, photos: [a], scopeName: "queue-b")
        queuedArt.index(library, photos: [b], scopeName: "queue-c")
        let queuedRecords = TaskCenter.shared.records.filter { $0.active && $0.recipe?.kind == "index" }
        precondition(queuedRecords.filter { $0.state == .queued }.count == 2)
        precondition(queuedRecords.filter { $0.state == .running }.count == 1)
        try await wait {
            let active = TaskCenter.shared.records.filter { $0.active && $0.recipe?.kind == "index" && $0.state == .running }
            precondition(active.count <= 1, "multiple batches ran together")
            return !ModelBatchQueue.shared.has(backend: "art") && !ModelBatchQueue.shared.has(backend: "quality")
        }
        precondition(queuedArt.error == nil && queuedQuality.error == nil)
        precondition(queuedArt.valid(a) && queuedArt.valid(b) && queuedQuality.valid(a), "queued scopes lost work")
        // Same-controller preemption must drain work, switch scope and resume
        // with the same record, reusing committed scores rather than rescoring.
        let switching = SemanticSearchModel(backend: "art")
        let switchPhotos = scoped.map { original -> Asset in
            var photo = original; photo.id = UUID().uuidString; return photo
        }
        switching.index(library, photos: switchPhotos, scopeName: "yield-original")
        try await wait { switching.rawScores.keys.contains(switchPhotos[0].id) }
        precondition(switching.indexing, "test batch finished before preemption")
        let originalRecord = TaskCenter.shared.activeRecords.first { $0.title.contains("yield-original") }!
        var urgentPhoto = scoped[0]; urgentPhoto.id = UUID().uuidString
        switching.index(library, photos: [urgentPhoto], scopeName: "yield-urgent")
        let urgentPosition = TaskCenter.shared.activeRecords.firstIndex { $0.title.contains("yield-urgent") }!
        TaskCenter.shared.move(from: IndexSet(integer: urgentPosition), to: 0)
        try await wait { switching.runScope == "yield-urgent" }
        let suspended = TaskCenter.shared.records.first { $0.id == originalRecord.id }!
        precondition(suspended.state == .queued && suspended.completed >= 1, "yield lost record/progress")
        try await wait { !ModelBatchQueue.shared.has(backend: "art") }
        precondition(switching.error == nil && switching.valid(urgentPhoto) && switchPhotos.allSatisfy { switching.valid($0) })
        precondition(TaskCenter.shared.records.filter { $0.title.contains("yield-original") }.count == 1, "resume created duplicate task")
        precondition(TaskCenter.shared.records.first { $0.id == originalRecord.id }?.failures.isEmpty == true, "yield counted as failure")
        print("PASS: running model batch yields to reordered same-model scope and resumes with saved progress")
        // A reset edit remains tracked, but its persisted result is already current.
        try await wait { TaskCenter.shared.loaded && library.rootsResolved && !library.checkingAnalysisEdits && !library.loading }
        var tracked = scoped[0]; tracked.analysisTracksEdits = true
        library.assets = [tracked]
        let automatic = SemanticSearchModel(backend: "quality")
        let beforeStatus = TaskCenter.shared.records.count
        await automatic.automaticallyRefreshEdits(library)
        precondition(TaskCenter.shared.records.count == beforeStatus, "startup must wait for persisted fingerprints")
        await automatic.refresh(library)
        precondition(automatic.valid(tracked))
        let beforeCurrent = TaskCenter.shared.records.count
        await automatic.automaticallyRefreshEdits(library)
        precondition(TaskCenter.shared.records.count == beforeCurrent, "current tracked edits must not create a batch after restart")
        tracked.rotation = 1
        library.assets = [tracked]
        await automatic.automaticallyRefreshEdits(library)
        precondition(ModelBatchQueue.shared.has(backend: "quality"), "changed edit must enqueue")
        try await wait { !ModelBatchQueue.shared.has(backend: "quality") }
        precondition(automatic.error == nil && automatic.valid(tracked), automatic.error ?? "changed edit was not scored")
        let afterEdit = TaskCenter.shared.records.count
        await automatic.automaticallyRefreshEdits(library)
        precondition(TaskCenter.shared.records.count == afterEdit, "completed edit must not enqueue again")
        let restartedAutomatic = SemanticSearchModel(backend: "quality")
        await restartedAutomatic.refresh(library)
        let afterRestart = TaskCenter.shared.records.count
        await restartedAutomatic.automaticallyRefreshEdits(library)
        precondition(TaskCenter.shared.records.count == afterRestart, "completed edit must remain current across restart")
        var missingScore = scoped[1]; missingScore.analysisTracksEdits = true
        library.assets = [tracked, missingScore]
        await restartedAutomatic.automaticallyRefreshEdits(library)
        let missingBatch = TaskCenter.shared.records.first { $0.active && $0.recipe?.backend == "quality" }
        precondition(missingBatch?.recipe?.ids == [missingScore.id], "only missing results should be enqueued")
        try await wait { !ModelBatchQueue.shared.has(backend: "quality") }
        precondition(restartedAutomatic.error == nil && restartedAutomatic.valid(missingScore))
        print("PASS: automatic edits wait for status, skip persisted current results, refresh changed/missing versions and survive restart")
        print("PASS: same-model and cross-model batch queue, exactly one active batch, all scopes completed")
        print("PASS: quality persistence, art/quality isolation, stale quality invalidation and quality sorting")
        print("PASS: pause after current photo, resume, scoped processing, stale rotation, durable failure and retry")
    }
}
