import Foundation

actor Gate {
    var opened = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if opened { return }; await withCheckedContinuation { waiters.append($0) } }
    func open() { opened = true; for waiter in waiters { waiter.resume() }; waiters = [] }
}
enum TestError: Error { case expected }
@main struct Tests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("prefetch-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func count() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: root.path).count) ?? -1 }
        let nextReady = Gate()
        var seen: [Int] = []
        try await runOneAhead([0,1,2], prepare: { item in
            let preview = PreparedPreview(directory: root)
            try Data([UInt8(item)]).write(to: preview.url)
            if item == 1 { await nextReady.open() }
            return preview
        }, consume: { item, result in
            let preview = try result.get()
            if item == 0 {
                await nextReady.wait()
                precondition(count() == 2, "must overlap exactly one preview with current consumer")
            }
            precondition(try! Data(contentsOf: preview.url) == Data([UInt8(item)]))
            seen.append(item)
        })
        precondition(seen == [0,1,2] && count() == 0)
        print("PASS overlap, bounded lookahead, order, success cleanup")

        let twoReady = Gate()
        var parallelSeen: [Int] = []
        try await runPrefetched(Array(0..<20), prepare: { item in
            let preview = PreparedPreview(directory: root)
            try Data([UInt8(item)]).write(to: preview.url)
            if item == 2 { await twoReady.open() }
            if item % 3 == 0 { try await Task.sleep(for: .milliseconds(10)) }
            return preview
        }, consume: { item, result in
            if item == 0 { await twoReady.wait() }
            let file = try result.get()
            precondition(count() <= 4, "bounded prepared files")
            precondition(try! Data(contentsOf: file.url) == Data([UInt8(item)]))
            parallelSeen.append(item)
        })
        precondition(parallelSeen == Array(0..<20) && count() == 0)
        print("PASS parallel decode, reordered completion, bounded files")
        let pendingDecode = Gate()
        do {
            try await runPrefetched([0,1,2,3,4], prepare: { item in
                let file = PreparedPreview(directory: root)
                try Data([0]).write(to: file.url)
                if item > 0 { await pendingDecode.open(); try await Task.sleep(for: .seconds(60)) }
                return file
            }, consume: { _, _ in await pendingDecode.wait(); throw TestError.expected })
            preconditionFailure("expected failure")
        } catch TestError.expected { }
        precondition(count() == 0)
        print("PASS parallel failure cancels all decoders and cleans buffered files")

        let preparing = Gate()
        do {
            try await runOneAhead([0,1,2], prepare: { item in
                let preview = PreparedPreview(directory: root)
                try Data([0]).write(to: preview.url)
                if item == 1 { await preparing.open(); try await Task.sleep(for: .seconds(60)) }
                return preview
            }, consume: { _, _ in await preparing.wait(); throw TestError.expected })
            preconditionFailure("expected failure")
        } catch TestError.expected { }
        precondition(count() == 0)
        print("PASS consumer failure cancels and drains in-flight decode")

        var recovered: [Int] = []
        try await runOneAhead([0,1,2], prepare: { item in
            let preview = PreparedPreview(directory: root)
            try Data([0]).write(to: preview.url)
            if item == 1 { throw TestError.expected }
            return preview
        }, consume: { item, result in
            if case .success = result { recovered.append(item) }
        })
        precondition(recovered == [0,2] && count() == 0)
        print("PASS recoverable decode failure keeps remaining items")

        let consuming = Gate(), release = Gate()
        let run = Task { @MainActor in
            try await runOneAhead([0,1,2], prepare: { item in
                let preview = PreparedPreview(directory: root)
                try Data([0]).write(to: preview.url)
                if item > 0 { try await Task.sleep(for: .seconds(60)) }
                return preview
            }, consume: { _, _ in await consuming.open(); await release.wait() })
        }
        await consuming.wait(); run.cancel(); await release.open()
        do { try await run.value; preconditionFailure("expected cancellation") } catch is CancellationError { }
        precondition(count() == 0)
        print("PASS user cancellation drains producer and cleans files")
    }
}
