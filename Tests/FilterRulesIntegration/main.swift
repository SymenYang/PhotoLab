import Foundation
import AppKit
@main struct FilterRulesIntegration {
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw CatalogError(message: "filter integration timeout")
    }
    @MainActor static func main() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("filter-integration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = LibraryModel(catalog: try Catalog(directory: dir))
        try await wait { !library.loading && !library.querying }
        var a = Asset(id: "a", rootID: "r", folder: "", name: "a", video: false,
                      files: [MediaFile(relativePath: "a.jpg", size: 1, modified: 1)], date: 1)
        a.captureDateChecked = true; a.tags = ["keep"]
        var b = a; b.id = "b"; b.name = "b"; b.tags = []
        var c = a; c.id = "c"; c.name = "c"; c.tags = []
        library.assets = [a, b, c]
        library.setArtScores(["a": 0.76, "b": 0.95], fingerprints: ["a": a.artFingerprint, "b": "stale"])
        library.setQualityScores(["a": 0.50, "b": 0.75], fingerprints: ["a": a.qualityFingerprint, "b": b.qualityFingerprint])
        library.filter.setRules([FilterRule(field: .art, value: "4")])
        try await wait { !library.querying }
        precondition(library.filtered.map(\.id) == ["a"], "stale art scores must be excluded")
        library.filter.setRules([FilterRule(field: .art, comparison: .equal, value: String(format: "%.2f", ArtScoring.display(0.76)))])
        try await wait { !library.querying }
        precondition(library.filtered.map(\.id) == ["a"], "AI threshold must match displayed five-point score exactly")
        library.filter.setRules([FilterRule(field: .quality, value: "4")])
        try await wait { !library.querying }
        precondition(library.filtered.map(\.id) == ["b"], "quality is distinct from art")
        library.setQualityScores(["a": 0.76, "b": 0.75], fingerprints: ["a": a.qualityFingerprint, "b": b.qualityFingerprint])
        try await wait { !library.querying }
        precondition(library.filtered.count == 2, "new AI scores must refresh filters without score sorting")
        var searches = 0
        var slowStarted = false
        let prints = Dictionary(uniqueKeysWithValues: library.assets.map { ($0.id, $0.analysisFingerprint) })
        let runner = RuleEmbeddingSearchModel { backend, _, request in
            if request["command"] as? String == "status" { return SemanticReply(ok: true, fingerprints: prints) }
            searches += 1
            precondition(Set((request["candidates"] as! [String: String]).keys) == ["a", "b", "c"], "OR rules must not prefilter embedding candidates")
            precondition(request["rankFusion"] as? Bool == true)
            if request["text"] as? String == "slow" {
                slowStarted = true
                try? await Task.sleep(for: .seconds(2)) // Simulate a reply arriving after cancellation.
                return SemanticReply(ok: true, hits: [SemanticHit(id: "c", score: 0.9)])
            }
            return SemanticReply(ok: true, hits: [SemanticHit(id: "b", score: 0.8)])
        }
        let embedding = FilterRule(field: .siglip, value: "0.5", query: "lake")
        let tag = FilterRule(join: .or, field: .tag, comparison: .equal, value: "keep")
        library.filter.setRules([embedding, tag])
        await runner.refresh(library, indexIdentity: "1")
        try await wait { !library.querying }
        precondition(library.filtered.map(\.id) == ["a", "b"], "embedding OR tag integrates without loss")
        var higher = embedding; higher.value = "0.9"
        library.filter.setRules([higher, tag])
        await runner.refresh(library, indexIdentity: "1")
        try await wait { !library.querying }
        precondition(searches == 1 && library.filtered.map(\.id) == ["a"], "threshold-only edits must reuse scores")
        var slow = embedding; slow.query = "slow"
        library.filter.setRules([slow])
        let pending = Task { await runner.refresh(library, indexIdentity: "1") }
        try await wait { slowStarted }
        pending.cancel()
        library.filter.setRules([embedding])
        await runner.refresh(library, indexIdentity: "1")
        await pending.value
        try await wait { !library.querying }
        precondition(library.filtered.map(\.id) == ["b"], "cancelled old query overwrote new results")
        library.filter.rootID = "other"
        try await wait { !library.querying }
        precondition(library.filtered.isEmpty, "scope change leaked cached scores")
        print("PASS filter integration: valid score refresh, full-scope OR queries, threshold cache reuse, cancellation, scope isolation")
    }
}
