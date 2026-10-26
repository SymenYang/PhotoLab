import AppKit
import Foundation

// This entire file is excluded from PhotoLab's production target. There is no
// LibraryModel, Catalog or photo decoder in this executable.
struct CatalogError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct SemanticReply: Decodable { let ok: Bool; let rawScore: Double? }
final class SemanticWorker: @unchecked Sendable {
    init(directory: URL, backend: String) {}
    func shutdown() async {}
    func request(_ request: [String: Any]) async throws -> SemanticReply {
        let config = try AIInstallation.configuration()
        guard let python = config["python"], let model = config["model"],
              FileManager.default.fileExists(atPath: model + "/installed.json") else {
            throw CatalogError(message: "Synthetic model not installed")
        }
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-B", AIInstallation.resources.appendingPathComponent("simulation_worker.py").path]
        process.standardInput = stdin; process.standardOutput = stdout
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request) + Data([10]))
        try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try JSONDecoder().decode(SemanticReply.self, from: data)
    }
}
enum ModelSimulation {
    static func bootstrapSource() throws -> (url: String, sha256: String) {
        let info = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: AIInstallation.resources.appendingPathComponent("simulation.json")))
        guard let address = info["archiveURL"], let url = URL(string: address), url.scheme == "http", url.host == "127.0.0.1", let hash = info["archiveSHA256"] else {
            throw CatalogError(message: "Simulation only allows loopback bootstrap")
        }
        return (address, hash)
    }
    static func validateIsolation() {
        guard let data = ProcessInfo.processInfo.environment["PHOTOLAB_DATA_DIR"],
              ProcessInfo.processInfo.environment["PHOTOLAB_AI_CONFIG"] == nil else { fatalError("Missing isolated simulation directory") }
        let path = URL(fileURLWithPath: data).resolvingSymlinksInPath()
        var ancestor = path
        while ancestor.path != "/" {
            if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".photolab-simulation").path) {
                precondition(ancestor.lastPathComponent.hasPrefix("photolab-model-simulation-") && ["/tmp", "/private/tmp"].contains(ancestor.deletingLastPathComponent().path)); return
            }
            ancestor.deleteLastPathComponent()
        }
        fatalError("Simulation refuses to use a non-test directory")
    }
    static func probe() async throws {
        let models = try AIInstallation.models()
        guard models.count == 1, models[0].installed else { throw CatalogError(message: "Receipt not recognized") }
        let config = try AIInstallation.configuration()
        precondition(config["model"] == models[0].directory.path)
        let reply = try await ModelService.request(backend: "siglip", directory: AIInstallation.root.appendingPathComponent("test-index"), request: ["command": "score"], priority: .interactive)
        precondition(reply.ok && reply.rawScore == 0.42)
        print("PASS: receipt, relocated resource paths and synthetic inference = 0.42")
    }
}
final class SimulationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ModelDownloadManager.shared.show()
    }
    func applicationWillTerminate(_ notification: Notification) { ModelDownloadManager.shared.cancel() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
@main struct SimulationApp {
    @MainActor static func main() {
        ModelSimulation.validateIsolation()
        if CommandLine.arguments.contains("--probe-legacy") {
            do {
                let model = try AIInstallation.models()[0]
                precondition(model.installed && model.externallyConfigured && !model.managedInstalled)
                let config = try AIInstallation.configuration(), original = try AIInstallation.baseConfiguration()
                precondition(config["model"] == original["model"] && config["python"] == original["python"])
                precondition(!FileManager.default.fileExists(atPath: AIInstallation.root.path))
                print("PASS: existing local model remains available without a download receipt or migration")
                exit(0)
            } catch { print(error); exit(1) }
        }
        if CommandLine.arguments.contains("--bootstrap-source") {
            do { print(try AIInstallation.bootstrapSource().url); exit(0) }
            catch { print(error); exit(1) }
        }
        if CommandLine.arguments.contains("--probe") || CommandLine.arguments.contains("--install") {
            Task {
                do {
                    if CommandLine.arguments.contains("--install") {
                        let manager = ModelDownloadManager.shared
                        manager.install(try AIInstallation.models()[0])
                        while manager.busy { try await Task.sleep(nanoseconds: 100_000_000) }
                        guard try AIInstallation.models()[0].installed else { throw CatalogError(message: manager.status) }
                    }
                    try await ModelSimulation.probe(); exit(0)
                }
                catch { print("FAIL: \(error)"); exit(1) }
            }
            dispatchMain()
        } else {
            let app = NSApplication.shared
            let delegate = SimulationDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.regular)
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}
