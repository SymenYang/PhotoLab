import Foundation

// Exactly one prepared item may run ahead of the serial consumer. Structured
// children are cancelled and drained before returning, including early failures.
@MainActor
func runOneAhead<Input: Sendable, Output: Sendable>(
    _ items: [Input],
    prepare: @escaping @Sendable (Input) async throws -> Output,
    consume: (Input, Result<Output, Error>) async throws -> Void
) async throws {
    try await withThrowingTaskGroup(of: Result<Output, Error>.self) { group in
        defer { group.cancelAll() }
        guard let first = items.first else { return }
        try Task.checkCancellation()
        group.addTask { do { return .success(try await prepare(first)) } catch { return .failure(error) } }
        for index in items.indices {
            guard let result = try await group.next() else { break }
            try Task.checkCancellation()
            if index + 1 < items.count {
                let next = items[index + 1]
                group.addTask { do { return .success(try await prepare(next)) } catch { return .failure(error) } }
            }
            try await consume(items[index], result)
        }
    }
}

// Own the temporary file even when decoding fails or is cancelled halfway.
final class PreparedPreview: @unchecked Sendable {
    let url: URL
    init(directory: URL) { url = directory.appendingPathComponent("input-\(UUID().uuidString).jpg") }
    deinit { try? FileManager.default.removeItem(at: url) }
}

// A bounded sliding window: two decoders, at most three items ahead of the
// serial inference. A slow early read cannot grow the reorder buffer indefinitely.
@MainActor
func runPrefetched<Input: Sendable, Output: Sendable>(
    _ items: [Input],
    prepare: @escaping @Sendable (Input) async throws -> Output,
    consume: (Input, Result<Output, Error>) async throws -> Void
) async throws {
    try await withThrowingTaskGroup(of: (Int, Result<Output, Error>).self) { group in
        defer { group.cancelAll() }
        var scheduled = 0, running = 0, next = 0
        var ready: [Int: Result<Output, Error>] = [:]
        func fill() {
            while running < 2 && scheduled < items.count && scheduled < next + 3 {
                let index = scheduled, item = items[scheduled]
                scheduled += 1; running += 1
                group.addTask {
                    do { return (index, .success(try await prepare(item))) }
                    catch { return (index, .failure(error)) }
                }
            }
        }
        fill()
        while next < items.count {
            try Task.checkCancellation()
            while ready[next] == nil {
                guard let (index, result) = try await group.next() else { return }
                running -= 1; ready[index] = result
                fill()
            }
            let index = next
            let result = ready.removeValue(forKey: index)!
            next += 1; fill()
            try Task.checkCancellation()
            try await consume(items[index], result)
        }
    }
}
