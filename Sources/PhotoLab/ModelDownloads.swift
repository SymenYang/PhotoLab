import SwiftUI
import AppKit
import CryptoKit

struct DownloadableModel: Decodable, Identifiable {
    let id, repo, revision, key, size, environment, title, license, licenseSHA256, licenseURL, notice: String
    var directory: URL { AIInstallation.root.appendingPathComponent("models/\(id)/\(revision)") }
    var installed: Bool { managedInstalled || externallyConfigured }
    var externallyConfigured: Bool {
        guard let config = try? AIInstallation.baseConfiguration(),
              let modelPath = config[key], let python = config[environment == "scoring" ? "artPython" : "python"],
              FileManager.default.isExecutableFile(atPath: python) else { return false }
        return FileManager.default.fileExists(atPath: modelPath + "/config.json") &&
            ["model.safetensors", "model.safetensors.index.json"].contains { FileManager.default.fileExists(atPath: modelPath + "/" + $0) }
    }
    var managedInstalled: Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("installed.json")),
              let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              receipt["accepted"] as? Bool == true, receipt["revision"] as? String == revision,
              receipt["licenseSHA256"] as? String == licenseSHA256,
              let files = receipt["files"] as? [String], !files.isEmpty else { return false }
        return files.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }
}

enum AIInstallation {
    static var root: URL {
        let base = ProcessInfo.processInfo.environment["PHOTOLAB_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhotoLab")
        return base.appendingPathComponent("AI")
    }
    static var resources: URL { Bundle.main.resourceURL!.appendingPathComponent("AI") }
    static func bootstrapSource() throws -> (url: String, sha256: String) {
#if PHOTOLAB_MODEL_SIMULATION
        return try ModelSimulation.bootstrapSource()
#else
        return ("https://github.com/astral-sh/python-build-standalone/releases/download/20250818/cpython-3.13.7%2B20250818-aarch64-apple-darwin-install_only.tar.gz",
                "4774f275706f3e250bad636d7cc6bf0e43c88611b7e4ea0418a631e743a3d5d5")
#endif
    }
    static func models() throws -> [DownloadableModel] {
        try JSONDecoder().decode([DownloadableModel].self, from: Data(contentsOf: resources.appendingPathComponent("models.json")))
    }
    static func baseConfiguration() throws -> [String: String] {
        if let override = ProcessInfo.processInfo.environment["PHOTOLAB_AI_CONFIG"] {
            return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: override)))
        }
        return (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: resources.appendingPathComponent("config.json")))) ?? [:]
    }
    static func configuration() throws -> [String: String] {
        var config = try baseConfiguration()
        for model in try models() where model.managedInstalled {
            config[model.key] = model.directory.path
            config[model.environment == "scoring" ? "artPython" : "python"] = root.appendingPathComponent("runtimes/\(model.environment)/bin/python3").path
        }
        config["colorWorker"] = resources.appendingPathComponent("color_worker.py").path
        config["jarvisPrompt"] = resources.appendingPathComponent("jarvis_prompt.py").path
        let helper = Bundle.main.resourceURL!.appendingPathComponent("ColorTools/Helpers/redlamp")
        if FileManager.default.isExecutableFile(atPath: helper.path) { config["redlamp"] = helper.path }
        return config
    }
}

@MainActor final class ModelDownloadManager: ObservableObject {
    static let shared = ModelDownloadManager()
    @Published var models: [DownloadableModel] = []
    @Published var activeID: String?
    @Published var status = "选择需要的模型，阅读许可后下载。"
    @Published var revision = 0
    private var process: Process?
    private var cancelled = false
    private var window: NSWindow?
    var busy: Bool { activeID != nil }
    func show() {
        do { models = try AIInstallation.models() } catch { status = error.localizedDescription }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 570), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "AI 模型管理"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ModelDownloadsView(manager: self))
            window.center(); self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
    }
    func cancel() { cancelled = true; process?.terminate(); status = "正在取消，已下载文件可在重试时复用…" }
    func install(_ model: DownloadableModel) {
        guard !busy else { return }
        activeID = model.id; cancelled = false
        Task {
            do {
                let licenseData = try Data(contentsOf: AIInstallation.resources.appendingPathComponent("licenses/\(model.license)"))
                guard SHA256.hash(data: licenseData).map({ String(format: "%02x", $0) }).joined() == model.licenseSHA256 else {
                    throw CatalogError(message: "许可证校验失败，请重新安装应用")
                }
                let root = AIInstallation.root
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let consent = root.appendingPathComponent("consent-\(model.id).json")
                let receipt: [String: Any] = ["id": model.id, "revision": model.revision, "licenseSHA256": model.licenseSHA256,
                    "accepted": true, "acceptedAt": ISO8601DateFormatter().string(from: Date()), "notice": model.notice,
                    "licenseURL": model.licenseURL]
                try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(to: consent, options: .atomic)
                let python = root.appendingPathComponent("python/bin/python3")
                if !FileManager.default.isExecutableFile(atPath: python.path) {
                    let bootstrap = try AIInstallation.bootstrapSource()
                    status = "下载独立 Python 3.13 运行环境…"
                    let archive = root.appendingPathComponent("python.tar.gz")
                    try await run("/usr/bin/curl", ["--fail", "--location", "--retry", "3", "--connect-timeout", "30", "--max-time", "1800", "-o", archive.path,
                        bootstrap.url])
                    status = "校验 Python 运行环境…"
                    let hash = try await Task.detached(priority: .utility) {
                        let handle = try FileHandle(forReadingFrom: archive); defer { try? handle.close() }
                        var hash = SHA256()
                        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
                        return hash.finalize().map { String(format: "%02x", $0) }.joined()
                    }.value
                    guard hash == bootstrap.sha256 else { throw CatalogError(message: "Python 校验失败，请重试") }
                    let staging = root.appendingPathComponent("python-staging")
                    try? FileManager.default.removeItem(at: staging)
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                    try await run("/usr/bin/tar", ["-xzf", archive.path, "-C", staging.path])
                    try FileManager.default.moveItem(at: staging.appendingPathComponent("python"), to: root.appendingPathComponent("python"))
                    try? FileManager.default.removeItem(at: archive)
                    try? FileManager.default.removeItem(at: staging)
                }
                status = "准备下载 \(model.title)…"
                try await run(python.path, ["-u", AIInstallation.resources.appendingPathComponent("install_model.py").path, model.id, root.path, consent.path])
                // Workers retain their startup config; restart only idle transports naturally
                // by shutting down their underlying processes through the shared service.
                await ModelService.embeddings.refreshConfiguration()
                await ModelService.scores.refreshConfiguration()
                status = "\(model.title) 已安装。可重新发起索引或使用相应功能。"
            } catch { status = cancelled ? "下载已取消。再次下载将校验并复用已完成的文件。" : "安装失败：\(error.localizedDescription)\n可重试，详细信息见安装日志。" }
            activeID = nil; process = nil; revision += 1
        }
    }
    private func run(_ executable: String, _ arguments: [String]) async throws {
        if cancelled { throw CancellationError() }
        let log = AIInstallation.root.appendingPathComponent("install.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log); defer { try? output.close() }
        let task = Process(); task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments
        task.standardOutput = output; task.standardError = output
        var environment = ProcessInfo.processInfo.environment
        for key in ["HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "PYTHONHOME", "PYTHONPATH"] { environment.removeValue(forKey: key) }
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        environment["SSL_CERT_FILE"] = "/etc/ssl/cert.pem"
        task.environment = environment
        try task.run(); process = task
        var offset: UInt64 = 0
        let reader = try FileHandle(forReadingFrom: log); defer { try? reader.close() }
        while task.isRunning {
            try await Task.sleep(nanoseconds: 300_000_000)
            try reader.seek(toOffset: offset)
            if let data = try reader.read(upToCount: 65536), !data.isEmpty {
                offset += UInt64(data.count)
                if let text = String(data: data, encoding: .utf8), let line = text.split(whereSeparator: \.isNewline).last { status = String(line.suffix(400)) }
            }
        }
        process = nil
        if cancelled { throw CancellationError() }
        guard task.terminationStatus == 0 else { throw CatalogError(message: "\(URL(fileURLWithPath: executable).lastPathComponent) 返回 \(task.terminationStatus)") }
    }
}

struct ModelDownloadsView: View {
    @ObservedObject var manager: ModelDownloadManager
    @State private var selected: DownloadableModel?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("本地 AI 模型").font(.title2.bold())
            Text("模型按需下载到本机，不随 PhotoLab 安装包分发。首次安装还会从 GitHub / PyPI 下载独立运行环境和依赖。推理在本机完成，不上传照片。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(manager.models) { model in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.title).bold()
                        Text("\(model.size) · \(model.id == "jarvis" ? "非商业、非生产许可" : "Apache 2.0")").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.externallyConfigured && !model.managedInstalled {
                        Text("已接入本地模型").font(.caption).foregroundStyle(.secondary)
                        Link("许可", destination: URL(string: model.licenseURL)!)
                    } else {
                        Button(model.installed ? "已安装 · 校验 / 修复…" : "下载…") { selected = model }.disabled(manager.busy)
                    }
                }.padding(.vertical, 7)
            }
            Divider()
            if manager.busy { ProgressView().controlSize(.small) }
            Text(manager.status).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button("打开模型目录") { try? FileManager.default.createDirectory(at: AIInstallation.root, withIntermediateDirectories: true); NSWorkspace.shared.open(AIInstallation.root) }
                Spacer()
                if manager.busy { Button("取消下载") { manager.cancel() } }
            }
        }.padding(24).frame(minWidth: 620, minHeight: 490)
        .sheet(item: $selected) { model in ModelConsentView(model: model) { manager.install(model) } }
    }
}

struct ModelConsentView: View {
    let model: DownloadableModel
    let accept: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var agreed = false
    var licenseText: String? { try? String(contentsOf: AIInstallation.resources.appendingPathComponent("licenses/\(model.license)"), encoding: .utf8) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("下载前确认 · \(model.title)").font(.title3.bold())
            Text("第三方模型不是 PhotoLab 自有或出售的模型，不因 PhotoLab 的开源许可而获得额外授权；使用与再分发受原权利人协议约束。").fixedSize(horizontal: false, vertical: true)
            Text(model.notice).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
            HStack {
                Link("模型来源", destination: URL(string: "https://huggingface.co/\(model.repo)/tree/\(model.revision)")!)
                Link("原始许可证", destination: URL(string: model.licenseURL)!)
                Text(model.size).foregroundStyle(.secondary)
            }
            Text("版本：\(model.revision)").font(.caption).textSelection(.enabled)
            ScrollView { Text(licenseText ?? "许可证缺失，无法下载。请重新安装 PhotoLab。").font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 200)
            Text("将连接 Hugging Face 获取模型；首次安装还会连接 GitHub 和 PyPI。照片不会发送给这些服务。请为模型及运行环境预留额外磁盘空间。").font(.caption).fixedSize(horizontal: false, vertical: true)
            Toggle(model.id == "jarvis" ? "我已阅读并同意原协议，确认仅用于其允许的非商业、非生产用途" : "我已阅读并同意遵守模型原始许可证", isOn: $agreed)
            HStack { Spacer(); Button("取消") { dismiss() }; Button("同意并下载") { dismiss(); accept() }.disabled(!agreed || licenseText == nil).buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 640)
    }
}
