import Darwin
import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampMasking

/// Moves Redlamp's caches into the test run's own folder, and its model compiles into the one every
/// run shares (`TestRun`), where a model is compiled once.
@_cdecl("RedlampTestRunBegin")
func testRunBegin() {
    let caches = TestRun.folder.appending(path: "Caches", directoryHint: .isDirectory)
    try? FileManager.default.removeItem(at: TestRun.folder)
    try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
    RedlampFolders.caches = caches
    RedlampFolders.compiledModels = TestRun.compiledModels
    atexit { try? FileManager.default.removeItem(at: TestRun.folder) }
}

struct TestRunTests {
    @Test func `the embeddings stay in the run's own folder, the model compiles in the shared one`() async {
        let caches = TestRun.folder.appending(path: "Caches")
        #expect(RedlampFolders.caches.path == caches.path)
        #expect(await EmbeddingCache.shared.root.path == caches.appending(path: "Embeddings").path)
        #expect(CompiledModels.root.path == TestRun.compiledModels.path)
    }
}
