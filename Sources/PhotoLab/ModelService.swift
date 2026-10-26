import Foundation

enum ModelRequestPriority: Int { case background = 0, crop = 1, interactive = 2 }
protocol ModelTransport: Sendable {
    func send(_ data: Data) async throws -> SemanticReply
    func shutdown() async
}
private final class ProcessModelTransport: ModelTransport, @unchecked Sendable {
    let worker: SemanticWorker
    init(family: String) {
        let root = ProcessInfo.processInfo.environment["PHOTOLAB_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhotoLab")
        worker = SemanticWorker(directory: root.appendingPathComponent("ModelRuntime/\(family)"), backend: "shared-" + family)
    }
    func send(_ data: Data) async throws -> SemanticReply {
        try await worker.request(JSONSerialization.jsonObject(with: data) as! [String: Any])
    }
    func shutdown() async { await worker.shutdown() }
}
private final class RequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}

// Shared scheduler for every model. The two transports reflect Python dependency
// environments, not separate model copies: fusion shares SigLIP/Qwen, IAA shares IQA.
actor ModelService {
    static let embeddings = ModelService(idleSeconds: nil, factory: { ProcessModelTransport(family: "embedding") })
    static let scores = ModelService(factory: { ProcessModelTransport(family: "art") })
    static func request(backend: String, directory: URL, request: [String: Any], priority: ModelRequestPriority) async throws -> SemanticReply {
        await TaskCenter.shared.registerWake("models") { Task { await Self.embeddings.wake(); await Self.scores.wake() } }
        let family = backend == "art" || backend == "quality" ? scores : embeddings
        let database = directory.appendingPathComponent(backend == "art" || backend == "quality" ? "scores.sqlite" : "vectors.sqlite").path
        let data = try JSONSerialization.data(withJSONObject: ["backend":backend, "database":database, "request":request])
        // One inference slot across both Python environments. Crop/search work
        // outranks even a manually promoted batch, without killing an inference.
        let control = WorkContext.ticket?.control ?? WorkControl(priority: 0)
        let floor = priority == .interactive ? 4 : priority == .crop ? 3 : 0
        return try await WorkScheduler.shared.run(.inference, control: control, minimumPriority: floor) {
            try await family.submit(data, priority: priority, gateGranted: true)
        }
    }
    private var refreshOnFinish = false
    func refreshConfiguration() async {
        if active || retiring { refreshOnFinish = true; return }
        retiring = true
        let previous = transport; transport = nil
        await previous?.shutdown()
        retiring = false; refreshOnFinish = false; pump()
    }
    private var preloadStarted = false
    func preloadEmbeddings(directory: URL) async {
        guard !preloadStarted else { return }
        preloadStarted = true
        // Separate requests preserve scheduler priority and let either model load
        // even if the other model is unavailable. No photos are needed or indexed.
        for backend in ["siglip", "qwen"] {
            let location = backend == "qwen" ? directory.appendingPathComponent("Qwen") : directory
            do {
                _ = try await Self.request(backend: backend, directory: location, request: ["command": "preload"], priority: .background)
                NSLog("PhotoLab %@ startup preload complete", backend)
            } catch {
                NSLog("PhotoLab %@ startup preload failed: %@", backend, error.localizedDescription)
            }
        }
    }
    private struct Pending {
        let id: UUID
        let data: Data
        let priority: ModelRequestPriority
        let control: WorkControl?
        let cancellation: RequestCancellation
        let continuation: CheckedContinuation<SemanticReply, Error>
    }
    private let factory: @Sendable () -> any ModelTransport
    private let idleNanoseconds: UInt64?
    private var transport: (any ModelTransport)?
    private var pending: [Pending] = []
    private var active = false
    private var retiring = false
    private var idleTask: Task<Void,Never>?
    private var idleToken = UUID()
    init(idleSeconds: Double? = 180, factory: @escaping @Sendable () -> any ModelTransport) {
        self.factory = factory; idleNanoseconds = idleSeconds.map { UInt64($0 * 1_000_000_000) }
    }
    func submit(_ data: Data, priority: ModelRequestPriority, gateGranted: Bool = false) async throws -> SemanticReply {
        let id = UUID(), cancellation = RequestCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !cancellation.cancelled else { continuation.resume(throwing: CancellationError()); return }
                idleTask?.cancel(); idleTask = nil; idleToken = UUID()
                pending.append(Pending(id: id, data: data, priority: priority, control: gateGranted ? nil : WorkContext.ticket?.control, cancellation: cancellation, continuation: continuation))
                pump()
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancelQueued(id) }
        }
    }
    private func cancelQueued(_ id: UUID) {
        if let index = pending.firstIndex(where: { $0.id == id }) {
            pending.remove(at: index).continuation.resume(throwing: CancellationError())
        }
        // In-flight requests keep their input alive until the worker replies.
        if !active && pending.isEmpty { scheduleIdle() }
    }
    private func rank(_ job: Pending) -> Int { max(job.priority.rawValue, job.control?.priority ?? 0) }
    func wake() { pump() }
    func releaseIdleForColor() async {
        guard !active, pending.isEmpty, !retiring else { return }
        idleTask?.cancel()
        await expire(idleToken)
    }
    private func pump() {
        guard !active && !retiring && !refreshOnFinish else { return }
        for job in pending where job.control?.cancelled == true { cancelQueued(job.id) }
        while let index = pending.indices.filter({ pending[$0].control?.paused != true }).max(by: { a,b in
            rank(pending[a]) == rank(pending[b]) ? a > b : rank(pending[a]) < rank(pending[b])
        }) {
            let job = pending.remove(at: index)
            if job.cancellation.cancelled || job.control?.cancelled == true { job.continuation.resume(throwing: CancellationError()); continue }
            if transport == nil { transport = factory() }
            let worker = transport!
            active = true
            Task {
                let result: Result<SemanticReply,Error>
                do { result = .success(try await worker.send(job.data)) }
                catch { result = .failure(error) }
                self.finish(job, result: result)
            }
            return
        }
        scheduleIdle()
    }
    private func finish(_ job: Pending, result: Result<SemanticReply,Error>) {
        active = false
        // A started index may already have committed its score/vector. Let the
        // caller account for that reply; its cancellation flag stops further work.
        job.continuation.resume(with: result)
        if refreshOnFinish {
            Task { await self.refreshConfiguration() }
        } else { pump() }
    }
    private func scheduleIdle() {
        guard let idleNanoseconds, transport != nil, !active, pending.isEmpty, !retiring else { return }
        idleTask?.cancel(); let key = UUID(); idleToken = key
        idleTask = Task {
            do { try await Task.sleep(nanoseconds: idleNanoseconds) } catch { return }
            await self.expire(key)
        }
    }
    private func expire(_ key: UUID) async {
        guard key == idleToken, !active, pending.isEmpty, let worker = transport else { return }
        retiring = true; transport = nil
        await worker.shutdown()
        retiring = false; idleTask = nil
        if refreshOnFinish { await refreshConfiguration() } else { pump() }
    }
    // Useful for deterministic scheduler diagnostics without exposing process internals.
    func queuedCount() -> Int { pending.count }
}
