import Foundation
// Only the process adapter is replaced here. Tests exercise the production scheduler.
struct SemanticReply { let ok: Bool }
final class SemanticWorker: @unchecked Sendable {
    init(directory: URL, backend: String) {}
    func request(_ request: [String:Any]) async throws -> SemanticReply { fatalError("Unexpected real transport") }
    func shutdown() async {}
}
actor FakeTransport: ModelTransport {
    var events: [String] = []
    var gate: CheckedContinuation<Void,Never>?
    var closed = 0
    func send(_ data: Data) async throws -> SemanticReply {
        let name = String(data:data,encoding:.utf8)!;events.append(name)
        if name == "hold" { await withCheckedContinuation { gate = $0 } }
        if name == "fail" { throw NSError(domain:"test",code:1) }
        return SemanticReply(ok:true)
    }
    func release() { gate?.resume();gate=nil }
    func shutdown() async { closed += 1 }
}
@main struct Tests {
    static func wait(_ f: () async -> Bool) async throws {
        for _ in 0..<500 { if await f() { return };try await Task.sleep(nanoseconds:10_000_000) }
        throw NSError(domain:"timeout",code:1)
    }
    static func main() async throws {
        let transport = FakeTransport(), service = ModelService(idleSeconds:0.05,factory:{transport})
        let first = Task { try await service.submit(Data("hold".utf8),priority:.background) }
        try await wait { await transport.events.count == 1 }
        let a = Task { try await service.submit(Data("a".utf8),priority:.background) }
        try await wait { await service.queuedCount() == 1 }
        let b = Task { try await service.submit(Data("b".utf8),priority:.background) }
        try await wait { await service.queuedCount() == 2 }
        let crop = Task { try await service.submit(Data("crop".utf8),priority:.crop) }
        let high = Task { try await service.submit(Data("manual".utf8),priority:.interactive) }
        let cancelled = Task { try await service.submit(Data("cancelled".utf8),priority:.interactive) }
        try await wait { await service.queuedCount() == 5 }
        cancelled.cancel()
        do { _ = try await cancelled.value;fatalError("queued cancellation failed") } catch is CancellationError {}
        first.cancel() // An in-flight committed reply still reaches its caller.
        await transport.release()
        _ = try await first.value; _ = try await a.value; _ = try await b.value; _ = try await crop.value; _ = try await high.value
        let events = await transport.events
        precondition(events == ["hold","manual","crop","a","b"],String(describing:events))
        try await wait { await transport.closed == 1 }
        _ = try await service.submit(Data("after-idle".utf8),priority:.interactive)
        do { _ = try await service.submit(Data("fail".utf8),priority:.interactive);fatalError("failure swallowed") } catch {}
        _ = try await service.submit(Data("after-error".utf8),priority:.background)
        try await wait { await transport.closed == 2 }
        let pausedTransport = FakeTransport(), pausedService = ModelService(idleSeconds: 5, factory: { pausedTransport })
        let pausedTicket = WorkTicket(id: UUID(), priority: 0)
        pausedTicket.control.pause(true)
        let pending = Task { try await WorkContext.$ticket.withValue(pausedTicket) { try await pausedService.submit(Data("paused".utf8), priority: .background) } }
        try await wait { await pausedService.queuedCount() == 1 }
        _ = try await pausedService.submit(Data("foreground".utf8), priority: .interactive)
        let beforeResume = await pausedTransport.events
        precondition(beforeResume == ["foreground"], "paused background blocked foreground")
        pausedTicket.control.pause(false); await pausedService.wake()
        _ = try await pending.value
        let afterResume = await pausedTransport.events
        precondition(afterResume == ["foreground", "paused"], "paused model request did not resume")
        // Once the global inference gate is granted, pausing must not suspend
        // the transport while it owns that gate and block interactive callers.
        pausedTicket.control.pause(true)
        _ = try await WorkContext.$ticket.withValue(pausedTicket) {
            try await pausedService.submit(Data("already-started".utf8), priority: .background, gateGranted: true)
        }
        let afterStarted = await pausedTransport.events
        precondition(afterStarted.last == "already-started")
        let residentTransport = FakeTransport(), residentService = ModelService(idleSeconds: nil, factory: { residentTransport })
        _ = try await residentService.submit(Data("resident".utf8), priority: .interactive)
        try await Task.sleep(nanoseconds: 100_000_000)
        let residentClosed = await residentTransport.closed
        precondition(residentClosed == 0, "resident embedding transport was shut down")
        let refreshTransport = FakeTransport(), refreshService = ModelService(idleSeconds: nil, factory: { refreshTransport })
        let ongoing = Task { try await refreshService.submit(Data("hold".utf8), priority: .interactive) }
        while await refreshTransport.events.isEmpty { await Task.yield() }
        await refreshService.refreshConfiguration()
        let closedBefore = await refreshTransport.closed
        precondition(closedBefore == 0, "configuration refresh interrupted active inference")
        await refreshTransport.release()
        _ = try await ongoing.value
        while await refreshTransport.closed == 0 { await Task.yield() }
        _ = try await refreshService.submit(Data("after-refresh".utf8), priority: .interactive)
        let refreshEvents = await refreshTransport.events
        precondition(refreshEvents == ["hold", "after-refresh"])
        print("PASS shared scheduler: priority, FIFO, queued cancellation, in-flight isolation, idle release, reuse after idle/error")
    }
}
