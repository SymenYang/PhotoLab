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
    var whiteBalance: String { object["whiteBalance"] as? String ?? "asShot" }
    var blackAndWhite: Bool { object["treatment"] as? String == "blackAndWhite" }
    static let curveKeys = ["pointCurve", "pointCurveRed", "pointCurveGreen", "pointCurveBlue"]
    func curve(_ key: String) -> [GradeCurvePoint] {
        (object[key] as? [[String: Double]])?.compactMap { point in
            guard let x = point["x"], let y = point["y"] else { return nil }
            return GradeCurvePoint(x: x, y: y)
        } ?? [.init(x: 0, y: 0), .init(x: 1, y: 1)]
    }
    var isNeutral: Bool { self == Self.neutral }
    mutating func setField(_ key: String, value: Any) throws {
        var fields = object; fields[key] = value
        var candidate = self
        candidate.settings = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        try candidate.validate(); self = candidate
    }
    mutating func setCurve(_ key: String, points: [GradeCurvePoint]) throws {
        guard Self.curveKeys.contains(key) else { throw CatalogError(message: "未知曲线通道") }
        try setField(key, value: points.map { ["x": $0.x, "y": $0.y] })
    }
    mutating func set(_ key: String, value: Double) throws {
        guard value.isFinite else { throw CatalogError(message: "调色参数不是有效数值") }
        var fields = object, numbers = values
        numbers[key] = value; fields["values"] = numbers
        if key == "wb.temperature" || key == "wb.tint" { fields["whiteBalance"] = "custom" }
        var candidate = self
        candidate.settings = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        try candidate.validate(); self = candidate
    }
    func validate() throws {
        let fields = try JSONSerialization.jsonObject(with: settings) as? [String: Any]
        let allowed: Set<String> = ["processVersion", "version", "values", "whiteBalance", "treatment", "pointCurve", "pointCurveRed", "pointCurveGreen", "pointCurveBlue"]
        guard settings.count < 200_000, let fields, fields["processVersion"] as? Int == 17,
              Set(fields.keys).isSubset(of: allowed), let numbers = fields["values"] as? [String: Double],
              numbers.values.allSatisfy({ $0.isFinite && abs($0) <= 100_000 }) else {
            throw CatalogError(message: "不支持或损坏的 Redlamp 全局调色参数")
        }
        for key in Self.curveKeys where fields[key] != nil {
            guard let points = fields[key] as? [[String: Double]], (2...256).contains(points.count),
                  points.allSatisfy({ point in
                      guard let x = point["x"], let y = point["y"] else { return false }
                      return x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
                  }), zip(points, points.dropFirst()).allSatisfy({ $0["x"]! < $1["x"]! }) else {
                throw CatalogError(message: "曲线坐标必须在 0 至 1 之间，且横坐标不能重叠")
            }
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

// Defaults and ranges mirror the vendored Redlamp ParameterSpec, including
// nonzero defaults. Missing recipe values must not appear as zero in the editor.
struct ManualColorControl: Identifiable {
    let title: String
    let key: String
    var range: ClosedRange<Double> = -100...100
    var step: Double = 1
    var defaultValue: Double = 0
    var id: String { key }
    static let whiteBalance = [
        Self(title: "色温 K", key: "wb.temperature", range: 2000...50000, step: 50, defaultValue: 5500),
        Self(title: "色调 · 绿 / 洋红", key: "wb.tint", range: -150...150),
    ]
    static let curveTone = [
        Self(title: "高光", key: "toneCurve.highlights"), Self(title: "亮调", key: "toneCurve.lights"),
        Self(title: "暗调", key: "toneCurve.darks"), Self(title: "阴影", key: "toneCurve.shadows"),
        Self(title: "阴影分界", key: "toneCurve.split.shadows", range: 10...40, defaultValue: 25),
        Self(title: "中间调分界", key: "toneCurve.split.midtones", range: 30...70, defaultValue: 50),
        Self(title: "高光分界", key: "toneCurve.split.highlights", range: 60...90, defaultValue: 75),
    ]
    static let gradingMix = [
        Self(title: "混合", key: "grading.blending", range: 0...100, defaultValue: 50),
        Self(title: "平衡", key: "grading.balance"),
    ]
    static func grading(_ band: String) -> [Self] { [
        Self(title: "色相", key: "grading." + band + ".hue", range: 0...360),
        Self(title: "饱和度", key: "grading." + band + ".saturation", range: 0...100),
        Self(title: "明亮度", key: "grading." + band + ".luminance"),
    ] }
    static let sharpening = [
        Self(title: "数量", key: "detail.sharpen.amount", range: 0...150, defaultValue: 40),
        Self(title: "半径", key: "detail.sharpen.radius", range: 0.5...3, step: 0.1, defaultValue: 1),
        Self(title: "细节", key: "detail.sharpen.detail", range: 0...100, defaultValue: 25),
        Self(title: "蒙版", key: "detail.sharpen.masking", range: 0...100),
    ]
    static let noise = [
        Self(title: "明亮度降噪", key: "detail.noise.luminance", range: 0...100),
        Self(title: "明亮度细节", key: "detail.noise.luminanceDetail", range: 0...100, defaultValue: 50),
        Self(title: "明亮度对比度", key: "detail.noise.luminanceContrast", range: 0...100),
        Self(title: "颜色降噪", key: "detail.noise.color", range: 0...100, defaultValue: 25),
        Self(title: "颜色细节", key: "detail.noise.colorDetail", range: 0...100, defaultValue: 50),
        Self(title: "颜色平滑度", key: "detail.noise.colorSmoothness", range: 0...100, defaultValue: 50),
    ]
    static let vignette = [
        Self(title: "数量", key: "effects.vignette.amount"),
        Self(title: "中点", key: "effects.vignette.midpoint", range: 0...100, defaultValue: 50),
        Self(title: "圆度", key: "effects.vignette.roundness"),
        Self(title: "羽化", key: "effects.vignette.feather", range: 0...100, defaultValue: 50),
        Self(title: "高光保护", key: "effects.vignette.highlights", range: 0...100),
    ]
    static let grain = [
        Self(title: "数量", key: "effects.grain.amount", range: 0...100),
        Self(title: "大小", key: "effects.grain.size", range: 0...100, defaultValue: 25),
        Self(title: "粗糙度", key: "effects.grain.roughness", range: 0...100, defaultValue: 50),
    ]
}

struct GradeCurvePoint: Equatable {
    var x: Double
    var y: Double
}

final class RedlampWorkingBase {
    let directory: URL
    let image: URL
    let sourceSize: CGSize
    init(directory: URL, image: URL, sourceSize: CGSize) {
        self.directory = directory; self.image = image; self.sourceSize = sourceSize
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
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
        typealias Balance = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Double>, UnsafeMutablePointer<Double>) -> Void
        typealias Curve = @convention(c) (UnsafePointer<Double>, Int32, UnsafeMutablePointer<Double>, Int32) -> Void
        let handle: UnsafeMutableRawPointer
        let create: Create
        let destroy: Destroy
        let open: Open
        let render: Render
        let balance: Balance
        let curve: Curve
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
            guard version() == 2 else { throw CatalogError(message: "Redlamp 原生接口版本不匹配，请重新构建应用") }
            create = try symbol("photolab_redlamp_create", Create.self)
            destroy = try symbol("photolab_redlamp_destroy", Destroy.self)
            open = try symbol("photolab_redlamp_open", Open.self)
            render = try symbol("photolab_redlamp_render", Render.self)
            balance = try symbol("photolab_redlamp_white_balance", Balance.self)
            curve = try symbol("photolab_redlamp_curve_samples", Curve.self)
        }
    }
    private static let library = Result { try Library() }
    private let api: Library
    private let session: UnsafeMutableRawPointer
    private(set) var size = CGSize.zero
    private(set) var sourceSize = CGSize.zero
    private var workingBase: RedlampWorkingBase?
    private(set) var whiteBalance: [String: Double] = ["wb.temperature": 5500, "wb.tint": 0]
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
        sourceSize = size
    }
    func open(_ base: RedlampWorkingBase) throws {
        try open(base.image)
        workingBase = base; sourceSize = base.sourceSize
    }
    func render(_ grade: RedlampGrade, previewLongEdge: Int? = nil, sixteenBit: Bool = false) throws -> CGImage {
        try grade.validate()
        var error = [CChar](repeating: 0, count: 4096)
        let pointer = grade.settings.withUnsafeBytes { bytes in
            api.render(session, bytes.bindMemory(to: UInt8.self).baseAddress!, Int32(bytes.count),
                       previewLongEdge.map { Int32(max(1, min(32768, $0))) } ?? 0,
                       previewLongEdge == nil || sixteenBit ? 1 : 0, &error, Int32(error.count))
        }
        guard let pointer else { throw CatalogError(message: String(cString: error)) }
        var temperature = 5500.0, tint = 0.0
        api.balance(session, &temperature, &tint)
        whiteBalance = ["wb.temperature": temperature, "wb.tint": tint]
        if previewLongEdge != nil { previews += 1 }
        return Unmanaged<CGImage>.fromOpaque(pointer).takeRetainedValue()
    }
    static func curveSamples(_ points: [GradeCurvePoint]) -> [GradeCurvePoint] {
        guard (2...256).contains(points.count), let api = try? library.get() else { return points }
        let coordinates = points.flatMap { [$0.x, $0.y] }
        var samples = [Double](repeating: 0, count: 129)
        api.curve(coordinates, Int32(points.count), &samples, Int32(samples.count))
        return samples.enumerated().map { GradeCurvePoint(x: Double($0.offset) / Double(samples.count - 1), y: $0.element) }
    }
}

enum RedlampBackend {
    // Protect only the cache. Decoding, disk I/O and Metal never hold this lock, so
    // a full-size export cannot block AI input preparation or another preview.
    private static let lock = NSLock()
    private static var bases: [String: RedlampWorkingBase] = [:]
    private static var baseOrder: [String] = []
    static func workingBase(_ source: URL, maxLongEdge: Int? = nil) throws -> RedlampWorkingBase? {
        guard Scanner.rawExtensions.contains(source.pathExtension.lowercased()) else { return nil }
        try Task.checkCancellation()
        let identity = try EditSource.read(source)
        let edge = maxLongEdge.map { max(1, min(32768, $0)) }
        let key = "\(source.path)|\(identity.size)|\(identity.modified)|native-17|\(edge ?? 0)"
        lock.lock()
        let cached = bases[key]
        if cached != nil { baseOrder.removeAll { $0 == key }; baseOrder.append(key) }
        lock.unlock()
        if let cached { return cached }
        let staging = try ColorRuntime.temporaryDirectory(), base = staging.appendingPathComponent("base.tif")
        do {
            let engine = try NativeColorEngine()
            try engine.open(source)
            try Task.checkCancellation()
            let size = engine.size
            let pixels = try engine.render(.neutral, previewLongEdge: edge, sixteenBit: true)
            try Task.checkCancellation()
            try PhotoEditStore.encode(pixels, to: base, tiff: true)
            try Task.checkCancellation()
            guard try EditSource.read(source) == identity else { throw CatalogError(message: "RAW 原片在读取时发生变化，请重试") }
            let result = RedlampWorkingBase(directory: staging, image: base, sourceSize: size)
            // Full-size TIFFs can be hundreds of MB: retain only during the export.
            if edge != nil {
                var evicted: [RedlampWorkingBase] = []
                lock.lock()
                if let previous = bases.updateValue(result, forKey: key) { evicted.append(previous) }
                baseOrder.removeAll { $0 == key }; baseOrder.append(key)
                while baseOrder.count > 2 {
                    if let previous = bases.removeValue(forKey: baseOrder.removeFirst()) { evicted.append(previous) }
                }
                lock.unlock()
                withExtendedLifetime(evicted) {}
            }
            return result
        } catch { try? FileManager.default.removeItem(at: staging); throw error }
    }
    static func render(_ source: URL, grade: RedlampGrade) throws -> CIImage {
        try grade.validate()
        try Task.checkCancellation()
        let engine = try NativeColorEngine()
        if let base = try workingBase(source) { try engine.open(base) }
        else { try engine.open(source) }
        try Task.checkCancellation()
        let image = try engine.render(grade)
        try Task.checkCancellation()
        guard image.bitsPerComponent == 16 else { throw CatalogError(message: "Redlamp 没有返回有效的16位图像") }
        return CIImage(cgImage: image)
    }
    static func preparePreview(_ source: URL, maxLongEdge: Int = 2048) throws -> NativeColorEngine {
        try Task.checkCancellation()
        let engine = try NativeColorEngine()
        if let base = try workingBase(source, maxLongEdge: maxLongEdge) { try engine.open(base) }
        else { try engine.open(source) }
        try Task.checkCancellation()
        return engine
    }
    static func modelInput(_ source: URL, directory: URL) throws -> URL {
        try Task.checkCancellation()
        // Share the bounded RGB base with the initial editor preview. Never prepare
        // a full-resolution TIFF just to feed a 1536px image to the model.
        let base = try workingBase(source, maxLongEdge: 2048)
        defer { withExtendedLifetime(base) {} }
        guard let image = CIImage(contentsOf: base?.image ?? source, options: [.applyOrientationProperty: true]) else {
            throw CatalogError(message: "无法准备 AI 输入图像")
        }
        let scale = min(1, 1536 / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = PhotoEditStore.context.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw CatalogError(message: "无法生成 sRGB 模型输入")
        }
        try Task.checkCancellation()
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
        progress("正在验证调色预览…", grade.englishPrompt ?? "")
        let preview = try preparePreview(source)
        _ = try preview.render(grade, previewLongEdge: 1536)
        try Task.checkCancellation()
        return grade
    }
}
