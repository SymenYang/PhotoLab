import Foundation
import SwiftUI

struct WorkYield: Error {}

// Thread-safe controls also support the existing blocking filesystem workers.
final class WorkControl: @unchecked Sendable {
    private let condition = NSCondition()
    private var stopped = false
    private var held = false
    private var yielding = false
    private var rank: Int
    private var position = 0
    init(priority: Int) { rank = priority }
    var priority: Int { condition.lock(); defer { condition.unlock() }; return rank }
    var queueOrder: Int { condition.lock(); defer { condition.unlock() }; return position }
    func setQueueOrder(_ value: Int) { condition.lock(); position = value; condition.unlock() }
    var cancelled: Bool { condition.lock(); defer { condition.unlock() }; return stopped }
    var shouldYield: Bool { condition.lock(); defer { condition.unlock() }; return yielding }
    func requestYield(_ value: Bool) { condition.lock(); yielding = value; condition.broadcast(); condition.unlock(); Task { await WorkScheduler.shared.pump() } }
    var paused: Bool { condition.lock(); defer { condition.unlock() }; return held }
    func setPriority(_ value: Int) { condition.lock(); rank = value; condition.broadcast(); condition.unlock(); Task { await WorkScheduler.shared.pump() } }
    func pause(_ value: Bool) { condition.lock(); held = value; condition.broadcast(); condition.unlock(); Task { await WorkScheduler.shared.pump() } }
    func cancel() { condition.lock(); stopped = true; condition.broadcast(); condition.unlock(); Task { await WorkScheduler.shared.pump() } }
    func wait() throws {
        condition.lock(); defer { condition.unlock() }
        while held && !stopped { condition.wait() }
        if stopped { throw CancellationError() }
    }
    func checkpoint() async throws {
        while paused && !cancelled && !shouldYield { try await Task.sleep(for: .milliseconds(100)) }
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
        if shouldYield { throw WorkYield() }
    }
}
enum WorkContext { @TaskLocal static var ticket: WorkTicket? }
final class WorkTicket: @unchecked Sendable {
    let id: UUID
    let control: WorkControl
    init(id: UUID, priority: Int) { self.id = id; control = WorkControl(priority: priority) }
    func checkpoint() async throws { try await control.checkpoint() }
    func run(_ operation: () async -> Void) async { await WorkContext.$ticket.withValue(self, operation: operation) }
    func stage(_ text: String) async { await TaskCenter.shared.update(id, detail: text) }
}
struct WorkRecipe: Codable, Equatable {
    var kind: String
    var rootID: String? = nil
    var folder: String? = nil
    var ids: [String] = []
    var backend: String? = nil
    var payload: Data? = nil
}
struct WorkRecord: Codable, Identifiable {
    enum State: String, Codable { case queued, running, paused, cancelling, completed, failed, cancelled, interrupted }
    var id = UUID()
    var title: String
    var detail = "准备中"
    var state = State.running
    var priority = 1 // 0 automatic, 1 explicit batch, 2 interactive
    var queueOrder: Int? = nil
    var completed = 0
    var total: Int? = nil
    var controllable = true
    var failures: [String] = []
    var recipe: WorkRecipe? = nil
    var created = Date()
    var updated = Date()
    var active: Bool { [.queued, .running, .paused, .cancelling].contains(state) }
}
@MainActor final class TaskCenter: ObservableObject {
    static let shared = TaskCenter()
    @Published private(set) var records: [WorkRecord] = []
    @Published private(set) var loaded = false
    @Published private(set) var persistenceError: String?
    private var backgroundPaused = false
    private var queuedIDs: Set<UUID> = []
    private var tickets: [UUID: WorkTicket] = [:]
    private var cancelActions: [UUID: () -> Void] = [:]
    private var retries: [UUID: () -> Void] = [:]
    private var handlers: [String: (WorkRecipe) -> Bool] = [:]
    private var wakeHandlers: [String: () -> Void] = [:]
    func registerWake(_ key: String, _ action: @escaping () -> Void) { wakeHandlers[key] = action }
    private func wake() { Task { await WorkScheduler.shared.pump() }; for action in wakeHandlers.values { action() } }
    private let storage: URL
    private let io = DispatchQueue(label: "photolab.task-history", qos: .utility)
    private var saveTask: Task<Void, Never>?
    init(storage: URL? = nil) {
        let base = ProcessInfo.processInfo.environment["PHOTOLAB_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhotoLab", isDirectory: true)
        self.storage = storage ?? base.appendingPathComponent("tasks.json", isDirectory: false)
        // Reading is asynchronous so a large history never delays the first frame.
        let path = self.storage
        io.async {
            do {
                guard FileManager.default.fileExists(atPath: path.path) else { Task { @MainActor in self.loaded = true; self.save(immediate: true) }; return }
                var saved = try JSONDecoder().decode([WorkRecord].self, from: Data(contentsOf: path))
                for i in saved.indices where saved[i].active { saved[i].state = .interrupted; saved[i].detail = "上次运行中断；已完成的缓存和索引保留" }
                let recovered = saved
                Task { @MainActor in
                    let current = Set(self.records.map(\.id))
                    self.records += recovered.filter { !current.contains($0.id) }; self.loaded = true; self.save(immediate: true)
                }
            } catch { Task { @MainActor in self.persistenceError = "无法读取任务历史：" + error.localizedDescription; self.loaded = true } }
        }
    }
    func interrupted(_ kind: String, backend: String) -> Bool {
        records.contains { $0.state == .interrupted && $0.recipe?.kind == kind && $0.recipe?.backend == backend }
    }
    var activeRecords: [WorkRecord] {
        records.filter(\.active).sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.queueOrder != $1.queueOrder { return ($0.queueOrder ?? 0) < ($1.queueOrder ?? 0) }
            return $0.created < $1.created
        }
    }
    var activeCount: Int { activeRecords.count }
    func move(from offsets: IndexSet, to destination: Int) {
        var ordered = activeRecords
        ordered.move(fromOffsets: offsets, toOffset: destination)
        for (position, record) in ordered.enumerated() {
            guard let i = records.firstIndex(where: { $0.id == record.id }) else { continue }
            // Manual ordering overrides automatic/batch tiers, but never promotes
            // background work into the reserved interactive resource lane.
            records[i].priority = 1; records[i].queueOrder = position
            tickets[record.id]?.control.setQueueOrder(position)
            tickets[record.id]?.control.setPriority(1)
        }
        wake(); save(immediate: true)
    }
    func begin(_ title: String, total: Int? = nil, priority: Int = 1, recipe: WorkRecipe? = nil, controllable: Bool = true, recorded: Bool = true, cancel: (() -> Void)? = nil, retry: (() -> Void)? = nil) -> WorkTicket {
        guard recorded else { return WorkTicket(id: UUID(), priority: priority) }
        var record = WorkRecord(title: title); record.total = total; record.priority = priority; record.recipe = recipe; record.controllable = controllable
        record.queueOrder = (records.compactMap(\.queueOrder).max() ?? -1) + 1
        let ticket = WorkTicket(id: record.id, priority: priority)
        ticket.control.setQueueOrder(record.queueOrder!)
        if backgroundPaused && (priority < 2 || recipe != nil) && controllable { ticket.control.pause(true); record.state = .paused }
        tickets[record.id] = ticket; cancelActions[record.id] = cancel; retries[record.id] = retry
        records.insert(record, at: 0)
        let expired = records.filter { !$0.active && $0.state != .interrupted }.dropFirst(300).map(\.id)
        records.removeAll { expired.contains($0.id) }; for id in expired { retries[id] = nil }
        save(immediate: true); return ticket
    }
    func queued(_ id: UUID, _ value: Bool) {
        guard let i = records.firstIndex(where: { $0.id == id }), records[i].active else { return }
        if value { queuedIDs.insert(id) } else { queuedIDs.remove(id) }
        if records[i].state != .paused { records[i].state = value ? .queued : .running }
        save()
    }
    func update(_ id: UUID, detail: String? = nil, completed: Int? = nil, total: Int? = nil, failure: String? = nil) {
        guard let i = records.firstIndex(where: { $0.id == id }), records[i].active else { return }
        if let detail { records[i].detail = detail }
        if let completed { records[i].completed = completed }
        if let total { records[i].total = total }
        if let failure { records[i].failures.append(failure) }
        records[i].updated = Date(); save()
    }
    func finish(_ id: UUID, error: String? = nil, cancelled: Bool = false) {
        guard let i = records.firstIndex(where: { $0.id == id }), records[i].active else { return }
        if let error { records[i].failures.append(error) }
        records[i].state = cancelled || tickets[id]?.control.cancelled == true ? .cancelled : records[i].failures.isEmpty ? .completed : .failed
        records[i].updated = Date(); tickets[id] = nil; cancelActions[id] = nil; queuedIDs.remove(id)
        save(immediate: true)
    }
    func pause(_ id: UUID, _ value: Bool) {
        guard let i = records.firstIndex(where: { $0.id == id }), records[i].controllable, let ticket = tickets[id], records[i].state != .cancelling else { return }
        ticket.control.pause(value); records[i].state = value ? .paused : (queuedIDs.contains(id) ? .queued : .running); wake(); save()
    }
    func cancel(_ id: UUID) {
        guard let i = records.firstIndex(where: { $0.id == id }), records[i].controllable, let ticket = tickets[id] else { return }
        ticket.control.cancel(); wake(); records[i].state = .cancelling
        cancelActions[id]?(); save()
    }
    func prioritize(_ id: UUID) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].priority = 2; tickets[id]?.control.setPriority(2); wake(); save()
    }
    func pauseAll(_ value: Bool) {
        backgroundPaused = value
        for record in records where record.active && (record.priority < 2 || record.recipe != nil) { pause(record.id, value) }
    }
    func register(_ kind: String, handler: @escaping (WorkRecipe) -> Bool) { handlers[kind] = handler }
    func canRetry(_ record: WorkRecord) -> Bool {
        guard !records.contains(where: { $0.active && $0.title == record.title }) else { return false }
        return retries[record.id] != nil || record.recipe.map { handlers[$0.kind] != nil } == true
    }
    func retry(_ record: WorkRecord) {
        guard !record.active, canRetry(record) else { return }
        var submitted = false
        if let retry = retries[record.id] { retry(); submitted = true }
        else if let recipe = record.recipe { submitted = handlers[recipe.kind]?(recipe) == true }
        if submitted, let i = records.firstIndex(where: { $0.id == record.id }) {
            records[i].state = .completed; records[i].detail = "已重新提交，见新的任务记录"; records[i].recipe = nil; retries[record.id] = nil; save()
        }
    }
    func checkpointRecipe(_ id: UUID, _ recipe: WorkRecipe) async throws {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].recipe = recipe
        try await flush()
    }
    func flush() async throws {
        while !loaded { try await Task.sleep(for: .milliseconds(20)) }
        saveTask?.cancel()
        let snapshot = records, path = storage
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            io.async {
                do {
                    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(snapshot).write(to: path, options: .atomic)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func dismiss(_ id: UUID) {
        guard records.first(where: { $0.id == id })?.active == false else { return }
        records.removeAll { $0.id == id }; retries[id] = nil; save()
    }
    func clearFinished() {
        let removed = records.filter { !$0.active && $0.state != .interrupted }.map(\.id)
        records.removeAll { removed.contains($0.id) }
        for id in removed { retries[id] = nil }
        save(immediate: true)
    }
    private func save(immediate: Bool = false) {
        guard loaded else { return }
        // Debounce progress; serialize atomic writes so older snapshots cannot win.
        saveTask?.cancel()
        saveTask = Task {
            if !immediate { do { try await Task.sleep(for: .milliseconds(250)) } catch { return } }
            let snapshot = records, path = storage
            io.async {
                do {
                    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(snapshot).write(to: path, options: .atomic)
                } catch { Task { @MainActor in self.persistenceError = "无法保存任务历史：" + error.localizedDescription } }
            }
        }
    }
}

// Resource limits are separate from the user-visible task list. A low-priority
// decode may use only one slot, leaving the second available to interactive work.
actor WorkScheduler {
    enum Resource: Hashable { case decode, copy, inference }
    static let shared = WorkScheduler()
    private struct Waiting {
        let id: UUID; let resource: Resource; let control: WorkControl; let minimumPriority: Int
        let continuation: CheckedContinuation<Void, Error>
    }
    private var pending: [Waiting] = []
    private var active: [Resource: Int] = [:]
    func acquire(_ resource: Resource, control: WorkControl, minimumPriority: Int = 0) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                pending.append(Waiting(id: id, resource: resource, control: control, minimumPriority: minimumPriority, continuation: continuation)); pump()
            }
        } onCancel: { Task { await self.remove(id) } }
    }
    private func remove(_ id: UUID) {
        if let i = pending.firstIndex(where: { $0.id == id }) { pending.remove(at: i).continuation.resume(throwing: CancellationError()) }
    }
    func queuedCount() -> Int { pending.count }
    func release(_ resource: Resource) { active[resource, default: 0] -= 1; pump() }
    func pump() {
        for job in pending where job.control.cancelled { remove(job.id) }
        for job in pending where job.control.shouldYield {
            if let i = pending.firstIndex(where: { $0.id == job.id }) { pending.remove(at: i).continuation.resume(throwing: WorkYield()) }
        }
        while let i = pending.indices.filter({ i in
            let job = pending[i], count = active[job.resource, default: 0]
            return !job.control.paused && count < (job.resource == .decode && job.control.priority >= 2 ? 2 : 1)
        }).max(by: { a,b in let left = pending[a], right = pending[b]
            let lp = max(left.control.priority, left.minimumPriority), rp = max(right.control.priority, right.minimumPriority)
            if lp != rp { return lp < rp }
            if left.control.queueOrder != right.control.queueOrder { return left.control.queueOrder > right.control.queueOrder }
            return a > b }) {
            let job = pending.remove(at: i); active[job.resource, default: 0] += 1; job.continuation.resume()
        }
    }
    func run<T>(_ resource: Resource, control: WorkControl, minimumPriority: Int = 0, operation: () async throws -> T) async throws -> T {
        try await acquire(resource, control: control, minimumPriority: minimumPriority)
        do { let result = try await operation(); release(resource); return result }
        catch { release(resource); throw error }
    }
}

struct TaskCenterPanel: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var center = TaskCenter.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("任务中心").font(.title2)
                Spacer()
                Button("暂停后台") { center.pauseAll(true) }
                Button("继续后台") { center.pauseAll(false) }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("拖动任务调整顺序，越靠上越优先；当前模型任务会在安全边界让位，已完成进度保留。暂停的任务保留在队列中，完成后自动移出。").font(.caption).foregroundStyle(.secondary)
            if let error = center.persistenceError { Text(error).foregroundStyle(.red) }
            List {
                    if center.activeRecords.isEmpty { Text("暂无任务").foregroundStyle(.secondary) }
                    ForEach(center.activeRecords) { record in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                                Text(record.title).font(.headline)
                                Spacer()
                                Text(label(record.state)).foregroundStyle(.secondary)
                            }
                            Text(record.detail).font(.caption).textSelection(.enabled)
                            if let total = record.total, total > 0 {
                                ProgressView(value: Double(min(record.completed, total)), total: Double(total))
                                Text("\(record.completed)/\(total)").font(.caption.monospacedDigit())
                            }
                            HStack {
                                if record.active && record.controllable {
                                    Button(record.state == .paused ? "继续" : "暂停") { center.pause(record.id, record.state != .paused) }.disabled(record.state == .cancelling)
                                    Button("取消") { center.cancel(record.id) }.disabled(record.state == .cancelling)
                                }
                                Text(record.created, style: .time).font(.caption).foregroundStyle(.secondary)
                            }
                            if !record.failures.isEmpty {
                                DisclosureGroup("失败详情（\(record.failures.count)）") {
                                    Text(record.failures.joined(separator: "\n")).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                                }
                            }
                        }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    }.onMove { offsets, destination in center.move(from: offsets, to: destination) }
            }
        }.padding().frame(width: 720, height: 560)
    }
    private func label(_ state: WorkRecord.State) -> String {
        switch state {
        case .queued: "排队中"; case .running: "进行中"; case .paused: "已暂停"; case .cancelling: "正在取消"; case .completed: "完成"
        case .failed: "有失败项"; case .cancelled: "已取消"; case .interrupted: "上次中断"
        }
    }
}


// A batch owns this slot until completion, cancellation, or cooperative yield. Interactive requests do
// not enter this queue; they preempt between inference requests on the GPU gate.
@MainActor final class ModelBatchQueue {
    static let shared = ModelBatchQueue()
    private struct Job {
        let key: String
        let backend: String
        let ticket: WorkTicket
        let ready: () -> Bool
        let start: (WorkTicket) -> Void
        let cancel: () -> Void
    }
    private var waiting: [Job] = []
    private var active: Job?
    func has(backend: String) -> Bool { active?.backend == backend || waiting.contains { $0.backend == backend } }
    func enqueue(key: String, title: String, total: Int, priority: Int, recipe: WorkRecipe,
                 ready: @escaping () -> Bool, start: @escaping (WorkTicket) -> Void, cancel: @escaping () -> Void) {
        guard active?.key != key, !waiting.contains(where: { $0.key == key }) else { return }
        let ticket = TaskCenter.shared.begin(title, total: total, priority: priority, recipe: recipe, cancel: { [weak self] in self?.cancel(key: key) })
        waiting.append(Job(key: key, backend: recipe.backend ?? "", ticket: ticket, ready: ready, start: start, cancel: cancel))
        TaskCenter.shared.queued(ticket.id, true)
        TaskCenter.shared.update(ticket.id, detail: "等待其他批量模型任务完成…")
        TaskCenter.shared.registerWake("model-batches") { [weak self] in self?.pump() }
        pump()
    }
    func pump() {
        if let active {
            let current = active.ticket.control
            let higher = waiting.contains { job in
                let candidate = job.ticket.control
                return !candidate.paused && !candidate.cancelled && (job.backend == active.backend || job.ready()) &&
                    (candidate.priority > current.priority || (candidate.priority == current.priority && candidate.queueOrder < current.queueOrder))
            }
            if !current.cancelled && (current.paused || higher) {
                current.requestYield(true)
                TaskCenter.shared.update(active.ticket.id, detail: "等待当前工作项结束后让位，已完成进度保留…")
            }
            return
        }
        while let i = waiting.indices.filter({ !waiting[$0].ticket.control.paused && waiting[$0].ready() }).max(by: {
            let left = waiting[$0].ticket.control, right = waiting[$1].ticket.control
            if left.priority != right.priority { return left.priority < right.priority }
            if left.queueOrder != right.queueOrder { return left.queueOrder > right.queueOrder }
            return $0 > $1
        }) {
            let job = waiting.remove(at: i)
            if job.ticket.control.cancelled { TaskCenter.shared.finish(job.ticket.id, cancelled: true); continue }
            active = job; TaskCenter.shared.queued(job.ticket.id, false); job.start(job.ticket); return
        }
    }
    private func cancel(key: String) {
        if let active, active.key == key { active.cancel(); return }
        if let i = waiting.firstIndex(where: { $0.key == key }) {
            let job = waiting.remove(at: i); TaskCenter.shared.finish(job.ticket.id, cancelled: true)
        }
        pump()
    }
    func yielded(_ id: UUID) {
        guard let job = active, job.ticket.id == id else { return }
        job.ticket.control.requestYield(false)
        active = nil; waiting.append(job)
        TaskCenter.shared.queued(id, true)
        TaskCenter.shared.update(id, detail: "已让位，等待按队列顺序继续…")
        pump()
    }
    func finished(_ id: UUID) {
        guard active?.ticket.id == id else { return }
        active = nil; pump()
    }
}
