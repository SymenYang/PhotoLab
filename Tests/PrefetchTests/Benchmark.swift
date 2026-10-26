import Foundation
import CryptoKit

actor BenchmarkWorker {
    let process = Process(), input = Pipe(), output = Pipe()
    init(root: URL, directory: URL) throws {
        process.executableURL = root.appendingPathComponent(".ai-runtime/bin/python")
        process.arguments = ["-u", root.appendingPathComponent("AI/worker.py").path, root.appendingPathComponent(".ai-model-qwen").path, directory.appendingPathComponent("vectors.sqlite").path, "qwen"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.standardError
        try process.run()
    }
    func index(_ file: URL, id: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["command":"index", "path":file.path,"id":id,"fingerprint":"benchmark"]) + Data([10])
        try input.fileHandleForWriting.write(contentsOf: data)
        var response = Data()
        while !response.contains(10) {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { throw CatalogError(message: "worker exited") }
            response.append(chunk)
        }
        let reply = try JSONDecoder().decode(SemanticReply.self, from: response)
        guard reply.ok else { throw CatalogError(message: reply.error ?? "index failure") }
    }
    func stop() { try? input.fileHandleForWriting.close(); process.waitUntilExit() }
}
struct BenchItem: Sendable { let asset: Asset; let url: URL }
@main struct Benchmark {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let directory = URL(fileURLWithPath: "/private/tmp/photolab-prefetch-benchmark-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try Catalog(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhotoLab"))
        let roots = try catalog.roots()
        let photos = try catalog.assets().filter { !$0.video }.sorted { $0.name < $1.name }
        let items = photos.prefix(8).compactMap { a -> BenchItem? in
            guard let r = roots.first(where: { $0.id == a.rootID }) else { return nil }
            return BenchItem(asset:a,url:URL(fileURLWithPath:r.path).appendingPathComponent(a.preferred.relativePath))
        }
        let worker = try BenchmarkWorker(root:root,directory:directory)
        let prepare: @Sendable (BenchItem) async throws -> PreparedPreview = { item in
            let file = PreparedPreview(directory:directory)
            try await semanticPreview(url:item.url,raw:item.asset.preferred.isRAW,rotation:item.asset.quarterTurns,destination:file.url)
            return file
        }
        let warm = try await prepare(items[0]); try await worker.index(warm.url,id:"warm")
        var expected: [String:String] = [:]
        var results: [[String:Any]] = []
        for (round, mode) in ["serial","prefetch","prefetch","serial"].enumerated() {
            var hashes: [String:String] = [:]
            let consume: (BenchItem, Result<PreparedPreview,Error>) async throws -> Void = { item, result in
                let file = try result.get()
                hashes[item.asset.id] = SHA256.hash(data:try Data(contentsOf:file.url)).map { String(format:"%02x",$0) }.joined()
                try await worker.index(file.url,id:"\(round)-\(item.asset.id)")
            }
            let start = Date()
            if mode == "prefetch" { try await runOneAhead(items,prepare:prepare,consume:consume) }
            else { for item in items { try await consume(item,.success(try await prepare(item))) } }
            let seconds = Date().timeIntervalSince(start)
            if expected.isEmpty { expected = hashes } else { precondition(hashes == expected, "model inputs changed") }
            results.append(["mode":mode,"images":items.count,"seconds":seconds,"sameInputBytes":true])
            print("\(mode): \(seconds) sec / \(items.count) images")
        }
        await worker.stop()
        let destination = root.appendingPathComponent("build/reports/prefetch-benchmark.json")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]).write(to:destination)
    }
}
