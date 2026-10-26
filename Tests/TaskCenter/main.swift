import Foundation

struct TestFailure: Error { let message: String }
@main struct TaskCenterTests {
    static func check(_ condition: Bool, _ message: String) throws { if !condition { throw TestFailure(message: message) } }
    @MainActor static func main() async {
        do { try await run(); print("PASS task controls, resource reservation, promotion, cancellation, durable recovery") }
        catch { print("FAIL \(error)"); exit(1) }
    }
    @MainActor static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("PHOTOLAB_DATA_DIR", root.path, 1)
        let center = TaskCenter(storage: root.appendingPathComponent("tasks.json"))
        while !center.loaded { try await Task.sleep(for: .milliseconds(10)) }
        let batch = center.begin("batch", total: 3, recipe: WorkRecipe(kind: "cache", rootID: "root"))
        let foreground = center.begin("foreground", priority: 2, recorded: false)
        try check(!center.records.contains { $0.id == foreground.id }, "foreground task was recorded")
        let write = center.begin("save marks", controllable: false)
        center.pauseAll(true)
        try check(batch.control.paused && !foreground.control.paused && !write.control.paused, "pause all blocked foreground or saves")
        center.pause(batch.id, false)
        try await batch.checkpoint()
        center.prioritize(batch.id)
        try check(batch.control.priority == 2, "priority did not reach controls")
        center.pauseAll(true)
        try check(batch.control.paused && !foreground.control.paused, "promoted batch escaped background pause")
        center.pauseAll(false)
        center.update(batch.id, completed: 1, failure: "one failed file")
        center.finish(batch.id)
        try check(center.records.first(where: { $0.id == batch.id })?.state == .failed, "partial failure reported as success")
        try check(!center.activeRecords.contains { $0.id == batch.id }, "finished task remained visible")
        let pending = center.begin("recover", recipe: WorkRecipe(kind: "scan", rootID: "root"))
        try await center.checkpointRecipe(pending.id, WorkRecipe(kind: "scan", rootID: "root"))
        let restored = TaskCenter(storage: root.appendingPathComponent("tasks.json"))
        while !restored.loaded { try await Task.sleep(for: .milliseconds(10)) }
        let record = restored.records.first(where: { $0.id == pending.id })!
        try check(record.state == .interrupted, "restart left phantom running task")
        var resumes = 0
        restored.register("scan") { _ in resumes += 1; return true }
        restored.retry(record)
        try check(resumes == 1 && restored.records.first(where: { $0.id == record.id })?.recipe == nil, "recovery recipe was not consumed")
        center.cancel(pending.id)
        do { try await pending.checkpoint(); throw TestFailure(message: "cancel did not stop work") } catch is CancellationError { }
        center.finish(pending.id)
        try check(center.records.first(where: { $0.id == pending.id })?.state == .cancelled, "cancelled task reported success")

        let scheduler = WorkScheduler()
        let low = WorkControl(priority: 0)
        try await scheduler.acquire(.decode, control: low)
        let queuedControl = WorkControl(priority: 0)
        let queued = Task { try await scheduler.acquire(.decode, control: queuedControl) }
        try await Task.sleep(for: .milliseconds(50))
        queuedControl.setPriority(2); await scheduler.pump()
        // A second decode can start only after interactive promotion.
        try await queued.value
        await scheduler.release(.decode)
        let cancelled = Task { try await scheduler.acquire(.decode, control: WorkControl(priority: 0)) }
        try await Task.sleep(for: .milliseconds(50)); cancelled.cancel()
        do { try await cancelled.value; throw TestFailure(message: "queued cancellation was ignored") } catch is CancellationError { }
        await scheduler.release(.decode)
        // No leaked permits or queued continuations after cancellation.
        try await scheduler.acquire(.decode, control: low); await scheduler.release(.decode)
        // One batch across backends, repeated submissions deduplicate, and a
        // queued cancellation cannot cancel the active owner.
        let batches = ModelBatchQueue()
        var starts: [String] = []
        var handles: [String: WorkTicket] = [:]
        func enqueue(_ key: String, backend: String) {
            batches.enqueue(key: key, title: key, total: 1, priority: 1,
                recipe: WorkRecipe(kind: "index", backend: backend), ready: { true },
                start: { ticket in starts.append(key); handles[key] = ticket }, cancel: { })
        }
        enqueue("batch-a", backend: "siglip")
        enqueue("batch-b", backend: "art")
        enqueue("batch-c", backend: "siglip")
        enqueue("batch-c", backend: "siglip")
        try check(starts == ["batch-a"], "batches ran concurrently")
        let b = TaskCenter.shared.records.first { $0.title == "batch-b" }!
        let c = TaskCenter.shared.records.filter { $0.title == "batch-c" }
        try check(b.state == .queued && c.count == 1, "queued state or deduplication failed")
        enqueue("batch-d", backend: "quality")
        let d = TaskCenter.shared.activeRecords.firstIndex { $0.title == "batch-d" }!
        let cPosition = TaskCenter.shared.activeRecords.firstIndex { $0.title == "batch-c" }!
        TaskCenter.shared.move(from: IndexSet(integer: d), to: cPosition)
        try check(TaskCenter.shared.activeRecords.map(\.title).suffix(2) == ["batch-d", "batch-c"], "display did not reflect manual order")
        TaskCenter.shared.cancel(b.id)
        try check(starts == ["batch-a"], "queued cancellation advanced active batch")
        TaskCenter.shared.finish(handles["batch-a"]!.id); batches.finished(handles["batch-a"]!.id)
        try check(starts == ["batch-a", "batch-d"], "manual queue order did not reach scheduler")
        TaskCenter.shared.finish(handles["batch-d"]!.id); batches.finished(handles["batch-d"]!.id)
        try check(starts == ["batch-a", "batch-d", "batch-c"], "cross-backend queue did not advance")
        TaskCenter.shared.finish(handles["batch-c"]!.id); batches.finished(handles["batch-c"]!.id)

        // Reordering preempts at a boundary, preserving the ticket/progress.
        enqueue("yield-a", backend: "art")
        enqueue("yield-b", backend: "art")
        let yieldingTicket = handles["yield-a"]!
        TaskCenter.shared.update(yieldingTicket.id, completed: 1)
        let promoted = TaskCenter.shared.activeRecords.firstIndex { $0.title == "yield-b" }!
        TaskCenter.shared.move(from: IndexSet(integer: promoted), to: 0)
        try check(yieldingTicket.control.shouldYield, "reordering did not request preemption")
        try check(handles["yield-b"] == nil, "new batch started before old batch drained")
        do { try await yieldingTicket.checkpoint(); throw TestFailure(message: "yield checkpoint was ignored") } catch is WorkYield { }
        batches.yielded(yieldingTicket.id)
        try check(handles["yield-b"] != nil, "promoted batch did not start")
        try check(TaskCenter.shared.activeRecords.first { $0.id == yieldingTicket.id }?.completed == 1, "yield lost progress")
        TaskCenter.shared.finish(handles["yield-b"]!.id); batches.finished(handles["yield-b"]!.id)
        try check(handles["yield-a"] === yieldingTicket && !yieldingTicket.control.shouldYield, "resume replaced or poisoned ticket")
        enqueue("pause-next", backend: "quality")
        TaskCenter.shared.pause(yieldingTicket.id, true)
        do { try await yieldingTicket.checkpoint(); throw TestFailure(message: "paused batch did not yield") } catch is WorkYield { }
        batches.yielded(yieldingTicket.id)
        try check(handles["pause-next"] != nil, "paused batch retained execution slot")
        TaskCenter.shared.finish(handles["pause-next"]!.id); batches.finished(handles["pause-next"]!.id)
        try check(TaskCenter.shared.activeRecords.first { $0.id == yieldingTicket.id }?.state == .paused, "pause state lost")
        TaskCenter.shared.cancel(yieldingTicket.id)
        try check(!batches.has(backend: "art"), "cancelled yielded job remained queued")

        // Interactive inference outranks an explicitly promoted batch, including
        // across the two model process families; it never overlaps an active call.
        let orderedGPU = WorkScheduler()
        try await orderedGPU.acquire(.inference, control: WorkControl(priority: 1))
        let early = WorkControl(priority: 1), later = WorkControl(priority: 1)
        early.setQueueOrder(0); later.setQueueOrder(1)
        var reordered: [String] = []
        let earlyTask = Task { try await orderedGPU.run(.inference, control: early) { reordered.append("early") } }
        while await orderedGPU.queuedCount() < 1 { try await Task.sleep(for: .milliseconds(10)) }
        let laterTask = Task { try await orderedGPU.run(.inference, control: later) { reordered.append("later") } }
        while await orderedGPU.queuedCount() < 2 { try await Task.sleep(for: .milliseconds(10)) }
        later.setQueueOrder(-1)
        await orderedGPU.release(.inference)
        try await earlyTask.value; try await laterTask.value
        try check(reordered == ["later", "early"], "resource waiters ignored manual order")
        let gpu = WorkScheduler()
        try await gpu.acquire(.inference, control: WorkControl(priority: 1))
        var inferenceOrder: [String] = []
        let bulkRequest = Task { try await gpu.run(.inference, control: WorkControl(priority: 2)) { inferenceOrder.append("batch") } }
        while await gpu.queuedCount() < 1 { try await Task.sleep(for: .milliseconds(10)) }
        let cropRequest = Task { try await gpu.run(.inference, control: WorkControl(priority: 2), minimumPriority: 3) { inferenceOrder.append("crop") } }
        while await gpu.queuedCount() < 2 { try await Task.sleep(for: .milliseconds(10)) }
        try check(inferenceOrder.isEmpty, "inference slot overlapped")
        await gpu.release(.inference)
        try await bulkRequest.value; try await cropRequest.value
        try check(inferenceOrder == ["crop", "batch"], "interactive request did not preempt queued batch")
        center.finish(foreground.id); center.finish(write.id)
    }
}
