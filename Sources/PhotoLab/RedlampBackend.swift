import Foundation
import CoreImage
import ImageIO
import CryptoKit
import Darwin

enum ColorPrompt {
    static func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) ||
            (0x20000...0x323AF).contains($0.value)
        }
    }
}

struct RedlampGrade: Codable, Equatable {
    var settings: Data
    var originalPrompt: String?
    var englishPrompt: String?
    var audit: String?
    var modelResponse: String?
    static var neutral: Self {
        Self(settings: Data(#"{"processVersion":17,"values":{},"whiteBalance":"asShot"}"#.utf8))
    }
    var object: [String: Any] { (try? JSONSerialization.jsonObject(with: settings)) as? [String: Any] ?? [:] }
    var values: [String: Double] { object["values"] as? [String: Double] ?? [:] }
    var isNeutral: Bool { self == Self.neutral }
    mutating func set(_ key: String, value: Double) throws {
        guard value.isFinite else { throw CatalogError(message: "调色参数不是有效数值") }
        var fields = object, numbers = values
        numbers[key] = value; fields["values"] = numbers
        settings = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        try validate()
    }
    func validate() throws {
        let fields = try JSONSerialization.jsonObject(with: settings) as? [String: Any]
        let allowed: Set<String> = ["processVersion", "version", "values", "whiteBalance", "treatment", "pointCurve", "pointCurveRed", "pointCurveGreen", "pointCurveBlue"]
        guard settings.count < 200_000, let fields, fields["processVersion"] as? Int == 17,
              Set(fields.keys).isSubset(of: allowed), let numbers = fields["values"] as? [String: Double],
              numbers.values.allSatisfy({ $0.isFinite && abs($0) <= 100_000 }) else {
            throw CatalogError(message: "不支持或损坏的 Redlamp 全局调色参数")
        }
    }
    static func imported(_ recipe: [String: Any], original: String, result: [String: Any]) throws -> Self {
        guard var fields = recipe["settings"] as? [String: Any], recipe["processVersion"] as? Int == 17 else {
            throw CatalogError(message: "Redlamp 返回了不兼容的参数格式")
        }
        fields["processVersion"] = 17
        fields["values"] = fields["values"] ?? [String: Double]()
        let grade = Self(settings: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
                         originalPrompt: original, englishPrompt: result["english"] as? String,
                         audit: result["audit"] as? String, modelResponse: result["response"] as? String)
        try grade.validate()
        return grade
    }
}

enum ColorRuntime {
    static func configuration() throws -> [String: String] {
        try AIInstallation.configuration()
    }

    static func path(_ key: String) throws -> URL {
        guard let value = try configuration()[key], FileManager.default.fileExists(atPath: value) else {
            throw CatalogError(message: "缺少本地调色资源：\(key)。请打开“选片 → AI 模型管理…”安装所需模型。")
        }
        return URL(fileURLWithPath: value)
    }
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("photolab-color-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func run(_ executable: URL, _ arguments: [String], directory: URL, timeout: Double = 180,
                    progress: (() -> Void)? = nil) throws {
        try Task.checkCancellation()
        let process = Process(), log = directory.appendingPathComponent(UUID().uuidString + ".log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        process.executableURL = executable; process.arguments = arguments
        process.standardOutput = handle; process.standardError = handle
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"; process.environment = environment
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Task<Never, Never>.isCancelled || Date() > deadline {
                process.terminate()
                let grace = Date().addingTimeInterval(2)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                try Task.checkCancellation()
                throw CatalogError(message: "本地调色超时，已停止进程。原调整未被替换。")
            }
            progress?()
            Thread.sleep(forTimeInterval: 0.2)
        }
        process.waitUntilExit()
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw CatalogError(message: "本地调色失败：" + String(detail.suffix(1800)))
        }
    }
}

final class NativeColorEngine {
    private final class Library {
        typealias Create = @convention(c) (UnsafeMutablePointer<CChar>?, Int32) -> UnsafeMutableRawPointer?
        typealias Destroy = @convention(c) (UnsafeMutableRawPointer) -> Void
        typealias Open = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<CChar>?, Int32) -> Int32
        typealias Render = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<UInt8>, Int32, Int32, Int32, UnsafeMutablePointer<CChar>?, Int32) -> UnsafeMutableRawPointer?
        let handle: UnsafeMutableRawPointer
        let create: Create
        let destroy: Destroy
        let open: Open
        let render: Render
        init() throws {
            let bundled = Bundle.main.privateFrameworksURL?.appendingPathComponent("PhotoLabRedlamp.framework/PhotoLabRedlamp")
            let path: URL
            if let bundled, FileManager.default.fileExists(atPath: bundled.path) { path = bundled }
            else { path = try ColorRuntime.path("nativeRedlamp") }
            guard let handle = dlopen(path.path, RTLD_NOW | RTLD_LOCAL) else {
                throw CatalogError(message: "无法加载常驻 Redlamp 引擎：" + String(cString: dlerror()))
            }
            self.handle = handle
            func symbol<Value>(_ name: String, _: Value.Type) throws -> Value {
                guard let address = dlsym(handle, name) else { throw CatalogError(message: "Redlamp 原生接口缺失：" + name) }
                return unsafeBitCast(address, to: Value.self)
            }
            let version = try symbol("photolab_redlamp_abi", (@convention(c) () -> Int32).self)
            guard version() == 1 else { throw CatalogError(message: "Redlamp 原生接口版本不匹配") }
            create = try symbol("photolab_redlamp_create", Create.self)
            destroy = try symbol("photolab_redlamp_destroy", Destroy.self)
            open = try symbol("photolab_redlamp_open", Open.self)
            render = try symbol("photolab_redlamp_render", Render.self)
        }
    }
    private static let library = Result { try Library() }
    private let api: Library
    private let session: UnsafeMutableRawPointer
    private(set) var size = CGSize.zero
    private(set) var opens = 0
    private(set) var previews = 0
    init() throws {
        api = try Self.library.get()
        var error = [CChar](repeating: 0, count: 4096)
        guard let session = api.create(&error, Int32(error.count)) else { throw CatalogError(message: String(cString: error)) }
        self.session = session
    }
    deinit { api.destroy(session) }
    func open(_ source: URL) throws {
        var width: Int32 = 0, height: Int32 = 0, error = [CChar](repeating: 0, count: 4096)
        let success = source.path.withCString { api.open(session, $0, &width, &height, &error, Int32(error.count)) }
        guard success != 0 else { throw CatalogError(message: String(cString: error)) }
        size = CGSize(width: Int(width), height: Int(height)); opens += 1
    }
    func render(_ grade: RedlampGrade, previewLongEdge: Int? = nil) throws -> CGImage {
        try grade.validate()
        var error = [CChar](repeating: 0, count: 4096)
        let pointer = grade.settings.withUnsafeBytes { bytes in
            api.render(session, bytes.bindMemory(to: UInt8.self).baseAddress!, Int32(bytes.count),
                       previewLongEdge.map { Int32(max(1, min(32768, $0))) } ?? 0,
                       previewLongEdge == nil ? 1 : 0, &error, Int32(error.count))
        }
        guard let pointer else { throw CatalogError(message: String(cString: error)) }
        if previewLongEdge != nil { previews += 1 }
        return Unmanaged<CGImage>.fromOpaque(pointer).takeRetainedValue()
    }
}

enum RedlampBackend {
    private static let lock = NSLock()
    private final class WorkingBase {
        let directory: URL
        let image: URL
        init(directory: URL, image: URL) { self.directory = directory; self.image = image }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }
    private static var bases: [String: WorkingBase] = [:]
    static func workingSource(_ source: URL, directory: URL) throws -> URL {
        guard Scanner.rawExtensions.contains(source.pathExtension.lowercased()) else { return source }
        let identity = try EditSource.read(source)
        let key = "\(source.path)|\(identity.size)|\(identity.modified)|native-17"
        if let cached = bases[key] { return cached.image }
        let staging = try ColorRuntime.temporaryDirectory(), base = staging.appendingPathComponent("base.tif")
        do {
            let engine = try NativeColorEngine()
            try engine.open(source)
            try PhotoEditStore.encode(engine.render(.neutral), to: base, tiff: true)
        }
        catch { try? FileManager.default.removeItem(at: staging); throw error }
        if bases.count >= 2, let oldest = bases.keys.sorted().first { bases.removeValue(forKey: oldest) }
        bases[key] = WorkingBase(directory: staging, image: base)
        return base
    }
    static func render(_ source: URL, grade: RedlampGrade) throws -> CIImage {
        try grade.validate()
        lock.lock(); defer { lock.unlock() }
        try Task.checkCancellation()
        let directory = try ColorRuntime.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try workingSource(source, directory: directory)
        let engine = try NativeColorEngine()
        try engine.open(input)
        let image = try engine.render(grade)
        guard image.bitsPerComponent == 16 else { throw CatalogError(message: "Redlamp 没有返回有效的16位图像") }
        return CIImage(cgImage: image)
    }
    static func preparePreview(_ source: URL) throws -> NativeColorEngine {
        lock.lock(); defer { lock.unlock() }
        let directory = try ColorRuntime.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try workingSource(source, directory: directory)
        let engine = try NativeColorEngine()
        try engine.open(input)
        return engine
    }
    static func modelInput(_ source: URL, directory: URL) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        let input = try workingSource(source, directory: directory)
        guard let image = CIImage(contentsOf: input, options: [.applyOrientationProperty: true]) else {
            throw CatalogError(message: "无法准备 AI 输入图像")
        }
        let scale = min(1, 1536 / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = PhotoEditStore.context.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw CatalogError(message: "无法生成 sRGB 模型输入")
        }
        let output = directory.appendingPathComponent("input.jpg")
        try PhotoEditStore.encode(cg, to: output, tiff: false)
        return output
    }
    static func generate(_ source: URL, prompt: String, progress: @escaping @Sendable (String, String) -> Void) throws -> RedlampGrade {
        guard !ColorPrompt.containsChinese(prompt) else { throw CatalogError(message: "请先翻译成英文并检查，再生成调色。") }
        let directory = try ColorRuntime.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        progress("正在准备未调色的 sRGB 图像…", "")
        let input = try modelInput(source, directory: directory)
        let request: [String: String] = ["image": input.path, "prompt": prompt,
            "model": try ColorRuntime.path("jarvisModel").path,
            "systemPrompt": try ColorRuntime.path("jarvisPrompt").path, "redlamp": try ColorRuntime.path("redlamp").path]
        let requestURL = directory.appendingPathComponent("request.json")
        try JSONSerialization.data(withJSONObject: request).write(to: requestURL)
        var previous = ""
        do {
            try ColorRuntime.run(ColorRuntime.path("python"), [try ColorRuntime.path("colorWorker").path, requestURL.path], directory: directory, timeout: 1200) {
                if let data = try? Data(contentsOf: directory.appendingPathComponent("status.json")),
                   let status = try? JSONDecoder().decode([String: String].self, from: data), let message = status["message"], message != previous {
                    previous = message; progress(message, status["english"] ?? "")
                }
            }
        } catch {
            try Task.checkCancellation()
            if let data = try? Data(contentsOf: directory.appendingPathComponent("error.json")),
               let details = try? JSONDecoder().decode([String: String].self, from: data), let message = details["error"] {
                throw CatalogError(message: message)
            }
            throw error
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("result.json"))
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], let recipe = result["recipe"] as? [String: Any] else {
            throw CatalogError(message: "调色模型没有返回可用的方案")
        }
        let grade = try RedlampGrade.imported(recipe, original: prompt, result: result)
        progress("正在验证全分辨率 Redlamp 渲染…", grade.englishPrompt ?? "")
        _ = try render(source, grade: grade)
        return grade
    }
}
