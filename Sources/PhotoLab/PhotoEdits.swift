import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

struct PhotoAdjustments: Codable, Equatable {
    var redlamp: RedlampGrade?
    var exposure = 0.0
    var temperature = 6500.0
    var tint = 0.0
    var asShot = true
    var highlights = 1.0
    var shadows = 0.0
    var contrast = 1.0
    var saturation = 1.0
    var quarterTurns = 0
    var straighten = 0.0
    // Bottom-left normalized coordinates AFTER orientation, rotation and straighten.
    var cropX = 0.0
    var cropY = 0.0
    var cropWidth = 1.0
    var cropHeight = 1.0
    var hasEffectiveChanges: Bool {
        var normalized = self
        // Stored temperature/tint are ignored while using the source white balance.
        if asShot { normalized.temperature = 6500; normalized.tint = 0 }
        if normalized.redlamp?.isNeutral == true { normalized.redlamp = nil }
        return normalized != PhotoAdjustments()
    }
    func validate() throws {
        try redlamp?.validate()
        let values = [exposure, temperature, tint, highlights, shadows, contrast, saturation, straighten, cropX, cropY, cropWidth, cropHeight]
        guard values.allSatisfy(\.isFinite), (-5...5).contains(exposure), (2000...50000).contains(temperature), (-150...150).contains(tint),
              (0...1).contains(highlights), (0...1).contains(shadows), (0.5...1.5).contains(contrast), (0...2).contains(saturation),
              (0...3).contains(quarterTurns), (-15...15).contains(straighten), cropX >= 0, cropY >= 0, cropWidth >= 0.000001, cropHeight >= 0.000001,
              cropX + cropWidth <= 1.000001, cropY + cropHeight <= 1.000001 else { throw CatalogError(message: "编辑参数无效或裁剪超出图片边界") }
    }
}
struct EditSource: Codable, Equatable {
    var filename: String
    var size: Int
    var modified: Double
    static func read(_ url: URL) throws -> Self {
        // URL resource values can retain a stale size/date after an external replacement.
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (values[.size] as? NSNumber)?.intValue, let date = values[.modificationDate] as? Date else { throw CatalogError(message: "无法读取原片信息") }
        return Self(filename: url.lastPathComponent, size: size, modified: date.timeIntervalSince1970)
    }
}
struct PhotoEditVersion: Codable {
    var id = UUID().uuidString
    var name = "当前编辑"
    var adjustments = PhotoAdjustments()
}
struct PhotoEditDocument: Codable {
    var schemaVersion = 1
    var pipelineVersion = 2
    var revision = UUID().uuidString
    var source: EditSource
    var activeVersionID: String
    var versions: [PhotoEditVersion]
    var tiffBytes = 0
    var thumbnailBytes = 0
    var cacheRevision: String?
    var outputWidth: Int?
    var outputHeight: Int?
    var outputColorSpace = "Display P3 SDR, 16-bit TIFF, LZW"
    init(source: EditSource) {
        self.source = source
        let version = PhotoEditVersion(); activeVersionID = version.id; versions = [version]
    }
    var adjustments: PhotoAdjustments {
        get { versions.first { $0.id == activeVersionID }!.adjustments }
        set { if let i = versions.firstIndex(where: { $0.id == activeVersionID }) { versions[i].adjustments = newValue } }
    }
    func validate() throws {
        guard schemaVersion == 1, (1...3).contains(pipelineVersion), versions.contains(where: { $0.id == activeVersionID }),
              Set(versions.map(\.id)).count == versions.count, tiffBytes >= 0, thumbnailBytes >= 0,
              tiffBytes <= 8_000_000_000, thumbnailBytes <= 20_000_000 else { throw CatalogError(message: "不支持的编辑文件版本或损坏的编辑文件") }
        for version in versions { try version.adjustments.validate() }
    }
}
struct EditEnvelope {
    var document: PhotoEditDocument
    var payloadOffset: UInt64
    var token: String
}

// One self-contained binary sidecar. Binary plist header + compressed 16-bit TIFF + JPEG thumbnail.
// Only the small header is read for discovery. No editing data is stored in the catalog.
enum PhotoEditStore {
    static let magic = Data("PLEDIT01".utf8)
    static let context = CIContext(options: [.cacheIntermediates: false, .workingFormat: CIFormat.RGBAh.rawValue])
    static let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
    static func sidecar(_ source: URL) -> URL { source.appendingPathExtension("photolab") }
    static func read(_ source: URL) throws -> EditEnvelope? {
        let url = sidecar(source)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        guard try handle.read(upToCount: 8) == magic, let bytes = try handle.read(upToCount: 8), bytes.count == 8 else { throw CatalogError(message: "编辑文件头损坏") }
        let count = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard count > 0, count < 4_000_000, let data = try handle.read(upToCount: Int(count)), data.count == Int(count) else { throw CatalogError(message: "编辑文件长度无效") }
        var doc = try PropertyListDecoder().decode(PhotoEditDocument.self, from: data)
        try doc.validate()
        let length = try handle.seekToEnd()
        if length != 16 + count + UInt64(doc.tiffBytes) + UInt64(doc.thumbnailBytes) { doc.cacheRevision = nil; doc.tiffBytes = 0; doc.thumbnailBytes = 0 }
        let token = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return EditEnvelope(document: doc, payloadOffset: 16 + count, token: token)
    }
    static func sourceMatches(_ source: URL, document: PhotoEditDocument) throws -> Bool {
        try EditSource.read(source) == document.source
    }
    static func preferredSource(_ urls: [URL]) -> URL? {
        urls.filter {
            guard FileManager.default.fileExists(atPath: sidecar($0).path) else { return false }
            // Keep damaged-file errors visible instead of silently hiding them.
            guard let envelope = try? read($0) else { return true }
            return envelope.document.adjustments.hasEffectiveChanges
        }.max {
            ((try? FileManager.default.attributesOfItem(atPath: sidecar($0).path)[.modificationDate]) as? Date ?? .distantPast) <
            ((try? FileManager.default.attributesOfItem(atPath: sidecar($1).path)[.modificationDate]) as? Date ?? .distantPast)
        }
    }
    static func analysisRevision(sources: [URL]) throws -> String? {
        guard let source = preferredSource(sources) else {
            guard sources.contains(where: { FileManager.default.isReadableFile(atPath: $0.path) }) else { throw CatalogError(message: "原片离线，保留已有分析版本") }
            return nil
        }
        guard let doc = try read(source)?.document else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let parameters = try encoder.encode(doc.adjustments)
        let identity = Data("\(source.lastPathComponent)|\(doc.pipelineVersion)|".utf8) + parameters
        return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }
    static func findPreferredSource(_ urls: [URL]) async throws -> URL? {
        try Task.checkCancellation()
        let lookup = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let source = preferredSource(urls)
            try Task.checkCancellation()
            return source
        }
        return try await withTaskCancellationHandler {
            let source = try await lookup.value
            try Task.checkCancellation()
            return source
        } onCancel: { lookup.cancel() }
    }
    static func siblings(asset: Asset, preferred: URL) -> [URL] {
        asset.files.map { preferred.deletingLastPathComponent().appendingPathComponent(($0.relativePath as NSString).lastPathComponent, isDirectory: false) }
    }
    static func sourceDefaults(_ source: URL) throws -> PhotoAdjustments {
        var a = PhotoAdjustments()
        if Scanner.rawExtensions.contains(source.pathExtension.lowercased()) {
            guard let raw = CIRAWFilter(imageURL: source) else { throw CatalogError(message: "系统暂不支持此 RAW 格式") }
            a.temperature = Double(raw.neutralTemperature); a.tint = Double(raw.neutralTint)
            try a.validate()
        }
        return a
    }
    static func decode(_ source: URL, adjustments: PhotoAdjustments, pipelineVersion: Int = 2, preserveHDR: Bool = false) throws -> CIImage {
        try adjustments.validate()
        if Scanner.rawExtensions.contains(source.pathExtension.lowercased()) {
            guard let decoder = CIRAWFilter(imageURL: source) else { throw CatalogError(message: "系统暂不支持此 RAW 格式") }
            decoder.scaleFactor = 1; decoder.isDraftModeEnabled = false
            // SDR is produced AFTER exposure and linear-space highlight/shadow work.
            // An SDR output does not require doing exposure on an already tone-mapped image.
            decoder.extendedDynamicRangeAmount = preserveHDR ? 1 : 0
            if pipelineVersion >= 2 {
                decoder.exposure = Float(adjustments.exposure)
                if decoder.isHighlightRecoverySupported { decoder.isHighlightRecoveryEnabled = true }
                if adjustments.highlights != 1 || adjustments.shadows != 0 {
                    let tone = RAWLinearToneFilter()
                    tone.highlightCompression = 1 - adjustments.highlights
                    tone.shadowLift = adjustments.shadows
                    decoder.linearSpaceFilter = tone
                }
            }
            if !adjustments.asShot {
                // Avoid a chromaticity -> temperature/tint -> chromaticity round-trip
                // when merely switching to manual at the exact as-shot values.
                let changed = abs(adjustments.temperature - Double(decoder.neutralTemperature)) > 0.00001 || abs(adjustments.tint - Double(decoder.neutralTint)) > 0.00001
                if pipelineVersion == 1 || changed {
                    decoder.neutralTemperature = Float(adjustments.temperature); decoder.neutralTint = Float(adjustments.tint)
                }
            }
            guard let image = decoder.outputImage else { throw CatalogError(message: "RAW 全分辨率解码失败") }
            return image
        }
        guard let image = CIImage(contentsOf: source, options: [.applyOrientationProperty: true, .expandToHDR: preserveHDR]) else { throw CatalogError(message: "无法读取全分辨率原片") }
        return image
    }
    static func render(_ source: URL, adjustments a: PhotoAdjustments, pipelineVersion: Int = 2, preserveHDR: Bool = false) throws -> CIImage {
        try a.validate()
        guard (1...3).contains(pipelineVersion) else { throw CatalogError(message: "不支持的 RAW 处理版本") }
        if let grade = a.redlamp {
            return geometry(try RedlampBackend.render(source, grade: grade), adjustments: a)
        }
        let raw = Scanner.rawExtensions.contains(source.pathExtension.lowercased())
        var image = try decode(source, adjustments: a, pipelineVersion: pipelineVersion, preserveHDR: preserveHDR)
        if !Scanner.rawExtensions.contains(source.pathExtension.lowercased()) && !a.asShot {
            image = image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: a.temperature, y: a.tint)])
        }
        if !raw || pipelineVersion == 1 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure])
                .applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": a.highlights, "inputShadowAmount": a.shadows])
        }
        image = image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: a.contrast, kCIInputSaturationKey: a.saturation])
        return geometry(image, adjustments: a)
    }
    static func geometry(_ input: CIImage, adjustments a: PhotoAdjustments) -> CIImage {
        var image = input
        if a.quarterTurns != 0 { image = image.oriented(a.quarterTurns == 1 ? .right : a.quarterTurns == 2 ? .down : .left) }
        let initial = image.extent
        image = image.transformed(by: CGAffineTransform(translationX: -initial.minX, y: -initial.minY))
        if a.straighten != 0 {
            let bounds = image.extent, angle = a.straighten * .pi / 180
            let rotated = image.transformed(by: CGAffineTransform(translationX: -bounds.midX, y: -bounds.midY))
                .transformed(by: CGAffineTransform(rotationAngle: angle))
            // Conservative inscribed rectangle, avoiding transparent corners.
            let inner = rotationBounds(bounds.size, degrees: a.straighten)
            image = rotated.cropped(to: inner).transformed(by: CGAffineTransform(translationX: -inner.minX, y: -inner.minY))
        }
        let bounds = image.extent
        let crop = CGRect(x: bounds.minX + bounds.width*a.cropX, y: bounds.minY + bounds.height*a.cropY,
                          width: bounds.width*a.cropWidth, height: bounds.height*a.cropHeight)
        let integral = CGRect(x: floor(crop.minX + 1e-7), y: floor(crop.minY + 1e-7), width: max(1, floor(crop.width + 1e-7)), height: max(1, floor(crop.height + 1e-7)))
        return image.cropped(to: integral).transformed(by: CGAffineTransform(translationX: -integral.minX, y: -integral.minY))
    }
    static func rotationBounds(_ size: CGSize, degrees: Double) -> CGRect {
        let w = size.width, h = size.height
        guard degrees != 0 else { return CGRect(x: -w/2, y: -h/2, width: w, height: h) }
        let angle = degrees * .pi / 180, c = abs(cos(angle)), s = abs(sin(angle))
        let scale = min(w / (w*c+h*s), h / (w*s+h*c))
        return CGRect(x: -w*scale/2, y: -h*scale/2, width: w*scale, height: h*scale).integral.insetBy(dx: 1, dy: 1)
    }
    static func cgImage(_ image: CIImage, sixteenBit: Bool = false) throws -> CGImage {
        guard let cg = context.createCGImage(image, from: image.extent, format: sixteenBit ? .RGBA16 : .RGBA8, colorSpace: colorSpace) else { throw CatalogError(message: "全分辨率渲染失败，可能内存不足") }
        return cg
    }
    static func encode(_ image: CGImage, to url: URL, tiff: Bool) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, (tiff ? UTType.tiff : UTType.jpeg).identifier as CFString, 1, nil) else { throw CatalogError(message: "无法创建图片缓存") }
        let properties: [CFString: Any] = tiff ? [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]] : [kCGImageDestinationLossyCompressionQuality: 0.88]
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CatalogError(message: "图片缓存写入失败") }
    }
    // expectedToken nil means CREATE ONLY. Conflicts never overwrite the other document.
    static func save(_ input: PhotoEditDocument, source: URL, expectedToken: String?, cache: Bool) throws -> EditEnvelope {
        guard try sourceMatches(source, document: input) else { throw CatalogError(message: "原片已变化，停止保存以免编辑绑定到错误文件") }
        var doc = input; doc.revision = UUID().uuidString; doc.cacheRevision = nil; doc.tiffBytes = 0; doc.thumbnailBytes = 0
        doc.outputWidth = nil; doc.outputHeight = nil
        let destination = sidecar(source), parent = destination.deletingLastPathComponent()
        let stage = parent.appendingPathComponent(".photolab-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        let full = stage.appendingPathComponent("result.tiff"), small = stage.appendingPathComponent("thumbnail.jpg")
        if cache {
            let image = try render(source, adjustments: doc.adjustments, pipelineVersion: doc.pipelineVersion)
            try encode(cgImage(image, sixteenBit: true), to: full, tiff: true)
            let scale = min(1, 480 / max(image.extent.width, image.extent.height))
            try encode(cgImage(image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))), to: small, tiff: false)
            doc.tiffBytes = try full.resourceValues(forKeys: [.fileSizeKey]).fileSize!
            doc.thumbnailBytes = try small.resourceValues(forKeys: [.fileSizeKey]).fileSize!
            doc.outputWidth = Int(image.extent.width); doc.outputHeight = Int(image.extent.height); doc.cacheRevision = doc.revision
        }
        try doc.validate()
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let metadata = try encoder.encode(doc)
        let temp = stage.appendingPathComponent("document")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let output = try FileHandle(forWritingTo: temp)
        do {
            try output.write(contentsOf: magic)
            var length = UInt64(metadata.count).bigEndian
            try output.write(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
            try output.write(contentsOf: metadata)
            if cache { for file in [full, small] {
                let reader = try FileHandle(forReadingFrom: file); defer { try? reader.close() }
                while let data = try reader.read(upToCount: 1_048_576), !data.isEmpty { try output.write(contentsOf: data) }
            } }
            try output.synchronize(); try output.close()
        } catch { try? output.close(); throw error }
        var coordinationError: NSError?, failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { coordinated in
            do {
                guard try read(source)?.token == expectedToken else { throw CatalogError(message: "编辑文件已被其他程序修改。未覆盖对方文件，请关闭后重新打开并核对。") }
                guard try sourceMatches(source, document: input) else { throw CatalogError(message: "原片在保存期间发生变化") }
                // POSIX rename replaces atomically on the same volume; never remove the old file first.
                guard rename(temp.path, coordinated.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            } catch { failure = error }
        }
        if let failure { throw failure }; if let coordinationError { throw coordinationError }
        return try read(source)!
    }
    // Reset is a coordinated, conflict-checked deletion, not an identity render cache.
    static func commit(_ document: PhotoEditDocument, source: URL, expectedToken: String?, cache: Bool) throws -> EditEnvelope? {
        try document.validate()
        guard document.versions.allSatisfy({ !$0.adjustments.hasEffectiveChanges }) else {
            return try save(document, source: source, expectedToken: expectedToken, cache: cache)
        }
        guard try sourceMatches(source, document: document) else { throw CatalogError(message: "原片已变化，未删除编辑记录") }
        var coordinationError: NSError?, failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: sidecar(source), options: .forDeleting, error: &coordinationError) { url in
            do {
                guard try read(source)?.token == expectedToken else { throw CatalogError(message: "编辑文件已被其他程序修改，未删除对方的编辑记录。请重新打开核对。") }
                guard try sourceMatches(source, document: document) else { throw CatalogError(message: "原片在保存期间发生变化") }
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            } catch { failure = error }
        }
        if let failure { throw failure }; if let coordinationError { throw coordinationError }
        return nil
    }
    private static let thumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    static func preview(_ source: URL, thumbnail: Bool, maxDimension: Int = 480) throws -> NSImage? {
        guard let envelope = try read(source) else { return nil }
        let doc = envelope.document
        // Cached results may be used when the source is offline, but not when a readable source has changed.
        if FileManager.default.fileExists(atPath: source.path), try !sourceMatches(source, document: doc) { throw CatalogError(message: "原片已变化，编辑结果需要重新确认") }
        let dimension = max(1, maxDimension)
        let cacheKey = "\(source.path)|\(doc.revision)|\(dimension)" as NSString
        if thumbnail, let image = thumbnailCache.object(forKey: cacheKey) { return image }
        func image(from cg: CGImage) -> NSImage {
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            if thumbnail { thumbnailCache.setObject(image, forKey: cacheKey, cost: cg.width * cg.height * 4) }
            return image
        }
        if doc.cacheRevision == doc.revision && doc.tiffBytes > 0 {
            let handle = try FileHandle(forReadingFrom: sidecar(source)); defer { try? handle.close() }
            let useSmall = thumbnail && dimension <= 480 && doc.thumbnailBytes > 0
            let count = useSmall ? doc.thumbnailBytes : doc.tiffBytes
            try handle.seek(toOffset: envelope.payloadOffset + (useSmall ? UInt64(doc.tiffBytes) : 0))
            if let bytes = try handle.read(upToCount: count), bytes.count == count,
               let imageSource = CGImageSourceCreateWithData(bytes as CFData, nil) {
                let cg = thumbnail ? CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: dimension, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) : CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
                if let cg { return image(from: cg) }
            }
        }
        var rendered = try render(source, adjustments: doc.adjustments, pipelineVersion: doc.pipelineVersion)
        if thumbnail { let scale = min(1, CGFloat(dimension) / max(rendered.extent.width, rendered.extent.height)); rendered = rendered.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        let cg = try cgImage(rendered)
        return image(from: cg)
    }
    private static let previewQueue = DispatchQueue(label: "photolab.edited-preview", qos: .userInitiated)
    private static let analysisPreviewQueue = DispatchQueue(label: "photolab.analysis-edited-preview", qos: .utility)
    static func loadPreview(sources: [URL], thumbnail: Bool, maxDimension: Int = 480, analysis: Bool = false) async -> (image: NSImage?, source: URL?, error: String?) {
        await withCheckedContinuation { continuation in
            (analysis ? analysisPreviewQueue : previewQueue).async {
                guard let source = preferredSource(sources) else { continuation.resume(returning: (nil, nil, nil)); return }
                do { continuation.resume(returning: (try autoreleasepool { try preview(source, thumbnail: thumbnail, maxDimension: maxDimension) }, source, nil)) }
                catch { continuation.resume(returning: (nil, source, "无法读取编辑结果：" + error.localizedDescription)) }
            }
        }
    }
    static func export(_ source: URL, to destination: URL, rotation: Int = 0, options: PhotoExportOptions = PhotoExportOptions()) throws -> URL {
        let a: PhotoAdjustments
        var pipelineVersion = 2
        if let envelope = try read(source) {
            guard try sourceMatches(source, document: envelope.document) else { throw CatalogError(message: "原片与编辑文件不匹配") }
            a = envelope.document.adjustments; pipelineVersion = envelope.document.pipelineVersion
        } else { a = PhotoAdjustments() }
        guard options.quality.isFinite, (0...1).contains(options.quality) else { throw CatalogError(message: "导出质量必须在 0 到 100% 之间") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + options.format.fileExtension)
        defer { try? FileManager.default.removeItem(at: tmp) }
        func write(preserveHDR: Bool) throws {
            var image = try render(source, adjustments: a, pipelineVersion: pipelineVersion, preserveHDR: preserveHDR)
            if rotation != 0 { image = image.oriented(rotation == 1 ? .right : rotation == 2 ? .down : .left) }
            if options.format == .tiff {
                try encode(cgImage(image, sixteenBit: true), to: tmp, tiff: true)
            } else {
                var properties: [CIImageRepresentationOption: Any] = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): options.quality]
                let primary: CIImage
                if preserveHDR {
                    primary = image.applyingFilter("CISystemToneMap")
                    properties[.hdrImage] = image
                } else { primary = image }
                try context.writeJPEGRepresentation(of: primary, to: tmp, colorSpace: colorSpace, options: properties)
            }
        }
        // HDR is a preference. Redlamp supplies SDR; other pipelines may fail
        // HDR decoding/encoding. Retry the same saved edit in SDR in either case.
        if options.format == .jpeg && options.preserveHDR && a.redlamp == nil {
            do { try write(preserveHDR: true) }
            catch {
                if FileManager.default.fileExists(atPath: tmp.path) { try FileManager.default.removeItem(at: tmp) }
                try write(preserveHDR: false)
            }
        } else { try write(preserveHDR: false) }
        return try Exporter.copy(source: tmp, destination: destination)
    }
}

// CIRAWFilter invokes this before its display tone curves. No 0...1 clamp:
// highlights above SDR white retain distinct values until the final SDR mapping.
final class RAWLinearToneFilter: CIFilter {
    @objc dynamic var inputImage: CIImage?
    var highlightCompression = 0.0
    var shadowLift = 0.0
    static let toneKernel = CIColorKernel(source: """
        kernel vec4 rawLinearTone(__sample p, float h, float s) {
            float y = max(dot(p.rgb, vec3(0.2126, 0.7152, 0.0722)), 0.0);
            float mapped = y / (1.0 + h * y);
            mapped += s * 0.15 * y / ((y + 0.1) * (1.0 + 4.0 * y));
            float scale = y > 0.0000001 ? mapped / y : 1.0;
            return vec4(p.rgb * scale, p.a);
        }
        """)!
    override var outputImage: CIImage? {
        guard let inputImage else { return nil }
        return Self.toneKernel.apply(extent: inputImage.extent, arguments: [inputImage, highlightCompression, shadowLift])
    }
}
