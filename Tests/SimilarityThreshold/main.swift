import Foundation
import AppKit
import Combine
@main struct SimilarityThresholdTests {
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<1000 { if ready() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw CatalogError(message: "threshold test timeout")
    }
    @MainActor static func main() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("photolab-threshold-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let media = dir.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let root = LibraryRoot(id: "threshold-test", path: media.path)
        let catalog = try Catalog(directory: dir.appendingPathComponent("catalog"))
        try catalog.save(root: root)
        let photos = try ["a", "b", "c"].map { id -> Asset in
            try Data([0]).write(to: media.appendingPathComponent(id + ".jpg"))
            var asset = Asset(id: id, rootID: root.id, folder: "", name: id, video: false,
                              files: [MediaFile(relativePath: id + ".jpg", size: 1, modified: 1)], date: 1)
            asset.captureDate = 1700000000; asset.captureDateChecked = true
            return asset
        }
        try catalog.save(assets: photos)
        let library = LibraryModel(catalog: catalog)
        let oldThreshold = library.similarityThreshold, oldAggregate = library.aggregateSimilar
        defer { library.similarityThreshold = oldThreshold; library.aggregateSimilar = oldAggregate }
        library.aggregateSimilar = true
        _ = TaskCenter.shared
        try await wait { !library.loading && library.rootsResolved && !library.querying && TaskCenter.shared.loaded }
        let base = catalog.directory.appendingPathComponent("SemanticSearch")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let prints = Dictionary(uniqueKeysWithValues: library.assets.map { ($0.id, $0.analysisFingerprint) })
        let config = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("AI/config.json")))
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: config["python"]!)
        fixture.arguments = ["-B", "-c", """
import sys, json, math
sys.path.insert(0, sys.argv[1])
from worker import Engine
import numpy as np
e = Engine(sys.argv[2], sys.argv[3])
fp = json.loads(sys.argv[4])
for id, degrees in [('a', 0), ('b', 10), ('c', 60)]:
    angle = math.radians(degrees)
    vector = np.array([math.cos(angle), math.sin(angle)], dtype=np.float32)
    e.db.execute('INSERT INTO embeddings VALUES(?,?,?,?)', (id,fp[id],e.key,vector.tobytes()))
e.db.commit()
""", Bundle.main.resourceURL!.appendingPathComponent("AI").path, config["model"]!, base.appendingPathComponent("vectors.sqlite").path, String(data: try JSONEncoder().encode(prints), encoding: .utf8)!]
        try fixture.run(); fixture.waitUntilExit(); precondition(fixture.terminationStatus == 0)
        let engine = SemanticSearchModel(backend: "siglip")
        engine.cancel() // Paused indexing must not block threshold changes.
        library.similarityThreshold = 0.9
        await engine.refreshSimilarityGroups(library)
        try await wait { !library.querying }
        precondition(library.visibleAssets.count == 2, "initial .9 grouping")
        // Reproduce SwiftUI's task(id: busy) cancellation trigger.
        var regroup: Task<Void, Never>?
        let observation = engine.$busy.dropFirst().sink { busy in if busy { regroup?.cancel() } }
        library.similarityThreshold = 0.999
        regroup = Task { await engine.automaticallyIndex(library) }
        await regroup?.value
        try await wait { !library.querying }
        precondition(library.visibleAssets.count == 3, "regroup self-cancelled when busy changed")
        precondition(engine.error == nil, engine.error ?? "")
        library.similarityThreshold = 0.2
        let cancelled = Task { await engine.refreshSimilarityGroups(library) }
        cancelled.cancel(); await cancelled.value
        // Retry exactly the cancelled threshold through the automatic cache gate.
        await engine.automaticallyIndex(library)
        try await wait { !library.querying }
        precondition(library.visibleAssets.count == 1, "cancelled threshold was incorrectly marked as applied")
        for (threshold, count) in [(0.999, 3), (0.1, 1), (0.2, 1)] {
            library.similarityThreshold = threshold
            await engine.refreshSimilarityGroups(library)
            try await wait { !library.querying }
            precondition(library.visibleAssets.count == count, "cached threshold transition failed")
        }
        precondition(engine.autoPaused && !engine.indexing, "threshold change resumed indexing")
        withExtendedLifetime(observation) {}
        print("PASS threshold regroup: .999 → 3, .2/.1 → 1; no self-cancellation; cancellation retry; paused index preserved")
    }
}
