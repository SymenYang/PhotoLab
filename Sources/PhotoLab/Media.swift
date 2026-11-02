import AppKit
import SwiftUI
import AVKit
import ImageIO
import CoreImage
import CryptoKit
import UniformTypeIdentifiers

enum ThumbnailResolution {
    static func tier(for points: CGFloat, scale: CGFloat) -> Int {
        let pixels = max(0, points) * max(1, scale)
        return pixels <= 480 ? 480 : pixels <= 960 ? 960 : 1440
    }
    static func cacheKey(_ base: String, dimension: Int) -> String {
        dimension == 480 ? base : "\(base)-thumb-\(dimension)"
    }
}

// One SDR cache for visible thumbnails and model inputs. Pixels are already rotated.
actor ImageCacheService {
    static let shared = ImageCacheService()
    static let analysisDimension = 960
    private var pending: [String: (task: Task<Data, Error>, control: WorkControl)] = [:]
    private let memory: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>(); cache.totalCostLimit = 64 * 1024 * 1024; return cache
    }()
    static func key(asset: Asset, dimension: Int) -> String {
        let text = "shared-sdr-srgb-v1|\(asset.analysisFingerprint)|\(dimension)"
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func data(asset: Asset, url: URL, dimension: Int, requireCurrentEdit: Bool = false) async throws -> Data {
        if let ticket = WorkContext.ticket { try await ticket.checkpoint(); await ticket.stage("读取或生成 \(dimension)px 图片…") }
        // Catalog edit tokens are refreshed after saves and on activation. Cache hits
        // must not probe originals (which may be on a slow/offline volume).
        if !requireCurrentEdit, let data = await existing(asset: asset, dimension: dimension) { return data }
        if asset.video { return try await cached(asset: asset, url: url, dimension: dimension, analysis: requireCurrentEdit) }
        let current = try await validatedAsset(asset, url: url)
        if requireCurrentEdit && current.analysisEditToken != asset.analysisEditToken { throw CatalogError(message: "编辑已变化，等待更新分析") }
        return try await cached(asset: current, url: url, dimension: dimension, analysis: requireCurrentEdit)
    }
    private func validatedAsset(_ asset: Asset, url: URL) async throws -> Asset {
        if asset.video { return asset }
        let sources = PhotoEditStore.siblings(asset: asset, preferred: url)
        let result = await Task.detached(priority: .utility) { Result { try PhotoEditStore.analysisRevision(sources: sources) } }.value
        var current = asset
        switch result {
        case .success(let revision): current.analysisEditToken = revision
        case .failure(let error):
            let online = await Task.detached(priority: .utility) { FileManager.default.isReadableFile(atPath: url.path) }.value
            if online { throw error }
        }
        return current
    }
    // One source decode per photo: acquire the 2560px SDR preview, decode that
    // JPEG once, and shrink in memory. Never decode an intermediate JPEG.
    func buildThumbnails(asset: Asset, url: URL) async throws {
        let ticket = WorkContext.ticket
        try await ticket?.checkpoint()
        let current = try await validatedAsset(asset, url: url)
        guard current.analysisEditToken == asset.analysisEditToken else { throw CatalogError(message: "编辑已变化，等待更新缓存") }
        let keys = Dictionary(uniqueKeysWithValues: [2560, 1440, 960, 480].map { ($0, Self.key(asset: asset, dimension: $0)) })
        let disk = await Task.detached(priority: .utility) {
            keys.compactMapValues { PreviewCache.shared.imageData(key: $0) }
        }.value
        if disk.count == keys.count { return }
        await ticket?.stage("生成 2560px 并逐级缩小至 1440/960/480px…")
        let largest: Data
        if let existing = disk[2560] { largest = existing }
        else { largest = try await cached(asset: asset, url: url, dimension: 2560, analysis: true) }
        try await ticket?.checkpoint()
        let missing = [1440, 960, 480].filter { disk[$0] == nil }
        let derived = try await Task.detached(priority: .utility) { () -> [Int: Data] in
            guard !missing.isEmpty else { return [:] }
            guard let image = NSImage(data: largest), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw CatalogError(message: "无法解码大尺寸缓存") }
            var ci = CIImage(cgImage: cg) // Already rotated and edited; do not transform twice.
            var result: [Int: Data] = [:]
            for dimension in [1440, 960, 480] {
                let scale = min(1, CGFloat(dimension) / max(ci.extent.width, ci.extent.height))
                ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                if missing.contains(dimension) { result[dimension] = try Self.jpeg(ci, dimension: dimension) }
            }
            return result
        }.value
        // Validate once for the batch before publishing any derived tiers.
        let latest = try await validatedAsset(asset, url: url)
        guard latest.analysisEditToken == asset.analysisEditToken else { throw CatalogError(message: "编辑已变化，忽略旧缩略图") }
        try await ticket?.checkpoint()
        try await Task.detached(priority: .utility) {
            // Also restore a memory-only largest tier if it was evicted from disk.
            if disk[2560] == nil, PreviewCache.shared.imageData(key: keys[2560]!) == nil {
                PreviewCache.shared.storeImage(largest, key: keys[2560]!, dimension: 2560)
            }
            for (dimension, data) in derived { PreviewCache.shared.storeImage(data, key: keys[dimension]!, dimension: dimension) }
            for key in keys.values where PreviewCache.shared.imageData(key: key) == nil {
                throw CatalogError(message: "缓存未落盘，请检查空间或缓存上限")
            }
        }.value
        for (dimension, data) in derived { memory.setObject(data as NSData, forKey: keys[dimension]! as NSString, cost: data.count) }
    }
    func existing(asset: Asset, dimension: Int) async -> Data? {
        let key = Self.key(asset: asset, dimension: dimension)
        if let data = memory.object(forKey: key as NSString) { return data as Data }
        guard let data = await Task.detached(priority: .userInitiated, operation: { PreviewCache.shared.imageData(key: key) }).value else { return nil }
        memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        return data
    }
    nonisolated static func jpeg(_ image: CIImage, dimension: Int = 960) throws -> Data {
        let scale = min(1, CGFloat(dimension) / max(image.extent.width, image.extent.height))
        let resized = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let data = context.jpegRepresentation(of: resized, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9]) else { throw CatalogError(message: "无法生成缓存图片") }
        return data
    }
    func clearMemory() { memory.removeAllObjects() }
    func original(url: URL, cacheKey: String, dimension: Int) async throws -> Data {
        let asset = Asset(id: cacheKey, rootID: "original-preview", folder: "", name: url.lastPathComponent, video: false,
                          files: [MediaFile(relativePath: url.lastPathComponent, size: 0, modified: 0)], date: 0)
        return try await cached(asset: asset, url: url, dimension: dimension, applyEdits: false)
    }
    private func cached(asset: Asset, url: URL, dimension: Int, applyEdits: Bool = true, analysis: Bool = false) async throws -> Data {
        let key = Self.key(asset: asset, dimension: dimension) + (applyEdits ? "" : "-original")
        if let data = memory.object(forKey: key as NSString) { return data as Data }
        let rank = analysis ? (WorkContext.ticket?.control.priority ?? 0) : 2
        if let job = pending[key] {
            if rank > job.control.priority {
                job.control.setPriority(rank)
                if dimension < Self.analysisDimension {
                    let parent = Self.key(asset: asset, dimension: Self.analysisDimension) + (applyEdits ? "" : "-original")
                    pending[parent]?.control.setPriority(rank)
                }
                await WorkScheduler.shared.pump()
            }
            return try await job.task.value
        }
        let control = WorkControl(priority: rank)
        let priority: TaskPriority = analysis ? .utility : .userInitiated
        let task = Task<Data, Error>(priority: priority) { try await WorkContext.$ticket.withValue(nil) {
            if let data = await Task.detached(priority: priority, operation: { PreviewCache.shared.imageData(key: key) }).value { return data }
            var sourceImage: NSImage?
            var rotation = asset.quarterTurns
            if dimension < Self.analysisDimension {
                sourceImage = NSImage(data: try await self.cached(asset: asset, url: url, dimension: Self.analysisDimension, applyEdits: applyEdits, analysis: control.priority < 2))
                rotation = 0
            } else {
                sourceImage = try await WorkScheduler.shared.run(.decode, control: control) {
                    if asset.video { return await MediaLoader.shared.videoFrame(url: url, dimension: dimension, analysis: control.priority < 2) }
                    let sources = PhotoEditStore.siblings(asset: asset, preferred: url)
                    let edited = applyEdits ? await PhotoEditStore.loadPreview(sources: sources, thumbnail: true, maxDimension: dimension, analysis: control.priority < 2, rotation: asset.quarterTurns) : (image: nil as NSImage?, source: nil as URL?, error: nil as String?)
                    if edited.source != nil {
                        guard let image = edited.image else { throw CatalogError(message: edited.error ?? "无法读取编辑结果") }
                        return image
                    }
                    return await MediaLoader.shared.photo(url: url, raw: asset.preferred.isRAW, full: false, hdr: false, maxDimension: CGFloat(dimension), analysis: control.priority < 2).image
                }
            }
            guard let sourceImage else { throw CatalogError(message: "无法生成预览，原片可能离线") }
            let data = try await Task.detached(priority: priority) {
                guard let cg = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw CatalogError(message: "无法解码图片") }
                var ci = CIImage(cgImage: cg)
                if rotation != 0 { ci = ci.oriented(rotation == 1 ? .right : rotation == 2 ? .down : .left) }
                let data = try Self.jpeg(ci, dimension: dimension)
                if applyEdits && !asset.video && dimension >= Self.analysisDimension {
                    let revision = try PhotoEditStore.analysisRevision(sources: PhotoEditStore.siblings(asset: asset, preferred: url))
                    guard revision == asset.analysisEditToken else { throw CatalogError(message: "编辑已变化，忽略旧预览") }
                }
                PreviewCache.shared.storeImage(data, key: key, dimension: dimension)
                return data
            }.value
            return data
        } }
        pending[key] = (task, control)
        do {
            let data = try await task.value; pending[key] = nil
            memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
            return data
        } catch { pending[key] = nil; throw error }
    }
    func analysis(asset: Asset, url: URL, destination: URL) async throws {
        let data = try await data(asset: asset, url: url, dimension: Self.analysisDimension, requireCurrentEdit: true)
        try Task.checkCancellation()
        try await Task.detached(priority: .utility) { try data.write(to: destination, options: .atomic) }.value
    }
}

struct MediaPreview {
    var image: NSImage?
    var duration: Double?
    var error: String?
}
// Immutable queue configuration and thread-safe NSCache; work results are delivered to the main actor.
final class MediaLoader: @unchecked Sendable {
    static let shared = MediaLoader()
    let analysisQueue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 2; q.qualityOfService = .utility; return q }()
    let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 2; q.qualityOfService = .userInitiated; return q }()
    let cachedQueue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 2; q.qualityOfService = .userInitiated; return q }()
    // A 100 MP HDR decode can require hundreds of MB; serialize HEIF HDR work across both input queues.
    let heifHDRQueue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 1; q.qualityOfService = .userInitiated; return q }()
    let cache = NSCache<NSString, NSImage>()
    let disk: URL
    init() {
        disk = PreviewCache.shared.root.appendingPathComponent("Thumbnails")
        try? FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
        cache.totalCostLimit = 128 * 1024 * 1024
    }
    func key(asset: Asset, file: MediaFile) -> String {
        SHA256.hash(data: Data("\(asset.id)|\(asset.identityPath(file))|\(file.size)|\(file.modified)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func thumbnail(asset: Asset, url: URL, maxDimension: Int = 480) async -> MediaPreview {
        let dimension = ThumbnailResolution.tier(for: CGFloat(maxDimension), scale: 1)
        do {
            let data = try await ImageCacheService.shared.data(asset: asset, url: url, dimension: dimension)
            guard !Task.isCancelled else { return MediaPreview() }
            return MediaPreview(image: NSImage(data: data))
        } catch {
            let online = await Task.detached(priority: .utility) { FileManager.default.isReadableFile(atPath: url.path) }.value
            if online { return MediaPreview(error: error.localizedDescription) }
            for fallback in [dimension, 960, 480, 1440] {
                let key = ImageCacheService.key(asset: asset, dimension: fallback)
                if let data = await Task.detached(priority: .userInitiated, operation: { PreviewCache.shared.imageData(key: key) }).value,
                   let image = NSImage(data: data) { return MediaPreview(image: image) }
            }
            if asset.analysisEditToken != nil { return MediaPreview(error: error.localizedDescription) }
            let legacy = ThumbnailResolution.cacheKey(key(asset: asset, file: asset.preferred), dimension: dimension)
            let fallback = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let image = NSImage(contentsOf: self.disk.appendingPathComponent(legacy + ".jpg")) ?? NSImage(contentsOf: self.disk.appendingPathComponent(self.key(asset: asset, file: asset.preferred) + ".jpg")) else { return nil }
                if asset.quarterTurns == 0 { return image }
                guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let data = try? ImageCacheService.jpeg(CIImage(cgImage: cg).oriented(asset.quarterTurns == 1 ? .right : asset.quarterTurns == 2 ? .down : .left), dimension: dimension) else { return nil }
                return NSImage(data: data)
            }.value
            return MediaPreview(image: fallback, error: fallback == nil ? error.localizedDescription : nil)
        }
    }
    func videoFrame(url: URL, dimension: Int, analysis: Bool = false) async -> NSImage? {
        await withCheckedContinuation { continuation in
            (analysis ? analysisQueue : queue).addOperation {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.maximumSize = CGSize(width: dimension, height: dimension); generator.appliesPreferredTrackTransform = true
                let image = (try? generator.copyCGImage(at: .zero, actualTime: nil)).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                continuation.resume(returning: image)
            }
        }
    }
    func photo(url: URL, raw: Bool, full: Bool, hdr: Bool, maxDimension: CGFloat = 2560, cacheKey: String? = nil, analysis: Bool = false, logicalSize: Bool = false) async -> MediaPreview {
        if !full && !hdr, let cacheKey {
            do {
                let data = try await ImageCacheService.shared.original(url: url, cacheKey: cacheKey, dimension: Int(maxDimension))
                guard !Task.isCancelled else { return MediaPreview() }
                return MediaPreview(image: NSImage(data: data))
            } catch {
                // Existing 2560 previews remain readable after migration, including offline.
                let old = PreviewCache.shared.root.appendingPathComponent("Previews/\(cacheKey)-sdr-\(Int(maxDimension)).jpg", isDirectory: false)
                let cached = await Task.detached(priority: .utility) { NSImage(contentsOf: old) }.value
                return MediaPreview(image: cached, error: cached == nil ? error.localizedDescription : nil)
            }
        }
        let memoryKey = cacheKey.map { "original-v2|\($0)|\(full)|\(hdr)|\(Int(maxDimension))|\(logicalSize)" }
        if let memoryKey, let image = cache.object(forKey:memoryKey as NSString) { return MediaPreview(image:image) }
        let cancellation = CancellationFlag()
        return await withTaskCancellationHandler(operation: {
          await withCheckedContinuation { continuation in
            let operation = BlockOperation {
                guard !cancellation.cancelled else { continuation.resume(returning: MediaPreview()); return }
                autoreleasepool {
                    let preview = cacheKey.flatMap { key in !full && !hdr ? PreviewCache.shared.root.appendingPathComponent("Previews/\(key)-sdr-\(Int(maxDimension)).jpg") : nil }
                    if let preview, let image = NSImage(contentsOf:preview) {
                        PreviewCache.shared.touch(preview); continuation.resume(returning:MediaPreview(image:image)); return
                    }
                    let url = cacheKey.map { PreviewCache.shared.original(url, key: $0) } ?? url
                    defer { if cacheKey != nil { PreviewCache.shared.release(url) } }
                    guard !cancellation.cancelled else { continuation.resume(returning: MediaPreview()); return }
                    var cg: CGImage?
                    var sourceSize: CGSize?
                    if raw, let filter = CIRAWFilter(imageURL: url) {
                        sourceSize = filter.nativeSize
                        if !full { filter.scaleFactor = Float(min(1,maxDimension/max(filter.nativeSize.width,filter.nativeSize.height))) }
                        filter.extendedDynamicRangeAmount = hdr ? 1 : 0
                        if var image = filter.outputImage {
                            // nativeSize may precede EXIF orientation. Match the decoded aspect.
                            if let native = sourceSize, (native.width > native.height) != (image.extent.width > image.extent.height) { sourceSize = CGSize(width:native.height,height:native.width) }
                            if !full { let scale = min(1, maxDimension / max(image.extent.width, image.extent.height)); image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
                            let space = CGColorSpace(name: hdr ? CGColorSpace.extendedLinearDisplayP3 : CGColorSpace.displayP3)!
                            cg = CIContext().createCGImage(image, from: image.extent, format: hdr ? .RGBAh : .RGBA8, colorSpace: space)
                        }
                    } else if let source = HEICHDRCompatibility.source(url: url, hdr: hdr) {
                        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                        let originalMax = max((properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 20000,
                                              (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 20000)
                        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? originalMax
                        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? originalMax
                        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
                        sourceSize = (5...8).contains(orientation) ? CGSize(width:height,height:width) : CGSize(width:width,height:height)
                        cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: full ? originalMax : maxDimension, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceDecodeRequest: hdr ? kCGImageSourceDecodeToHDR : kCGImageSourceDecodeToSDR] as CFDictionary)
                    }
                    guard !cancellation.cancelled else { continuation.resume(returning: MediaPreview()); return }
                    guard let cg else { continuation.resume(returning: MediaPreview(error: "原片离线，或系统暂不支持此格式。可返回网格查看缓存。")); return }
                    if let preview, let destination = CGImageDestinationCreateWithURL(preview as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                        CGImageDestinationAddImage(destination,cg,[kCGImageDestinationLossyCompressionQuality:0.9] as CFDictionary)
                        if CGImageDestinationFinalize(destination) { PreviewCache.shared.record(preview,kind:"preview") }
                    }
                    let pixels = CGSize(width:cg.width,height:cg.height)
                    let image = NSImage(cgImage:cg,size:logicalSize ? (sourceSize ?? pixels) : pixels)
                    let cost = cg.bytesPerRow*cg.height
                    if let memoryKey, cost <= 64*1024*1024 { self.cache.setObject(image,forKey:memoryKey as NSString,cost:cost) }
                    continuation.resume(returning: MediaPreview(image:image))
                }
            }
            operation.queuePriority = analysis ? .normal : .veryHigh
            if analysis { analysisQueue.addOperation(operation); return }
            cachedQueue.addOperation {
                let local = cacheKey.map { key in
                    let original = PreviewCache.shared.root.appendingPathComponent("Originals/" + key + "." + url.pathExtension)
                    let preview = PreviewCache.shared.root.appendingPathComponent("Previews/\(key)-sdr-\(Int(maxDimension)).jpg")
                    return FileManager.default.fileExists(atPath:original.path) || (!full && !hdr && FileManager.default.fileExists(atPath:preview.path))
                } ?? false
                let heifHDR = hdr && !raw && ["heic", "heif"].contains(url.pathExtension.lowercased())
                (heifHDR ? self.heifHDRQueue : (local ? self.cachedQueue : self.queue)).addOperation(operation)
            }
          }
        }, onCancel: { cancellation.cancel() })
    }
    func trimCache() { DispatchQueue.global(qos: .utility).async { PreviewCache.shared.migrateAndTrim() } }

}

struct Thumbnail: View {
    @Environment(\.displayScale) private var displayScale
    @EnvironmentObject var library: LibraryModel
    var asset: Asset
    var url: URL?
    @State private var image: NSImage?
    @State private var failure = false
    @State private var dimension = 480
    @State private var loadedIdentity: String?
    private var identity: String { "\(asset.analysisFingerprint)|\(url?.path ?? "")|\(library.editRevision)" }
    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
            if let image {
                GeometryReader { geometry in
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
            }
            else if failure { Image(systemName: "externaldrive.badge.exclamationmark").font(.title).foregroundStyle(.secondary) }
            else { ProgressView().controlSize(.small) }
        }
        .onGeometryChange(for: Int.self) { geometry in
            ThumbnailResolution.tier(for: max(geometry.size.width, geometry.size.height), scale: displayScale)
        } action: { dimension = $0 }
        .task(id: "\(identity)|\(dimension)") {
            let requestedIdentity = identity
            if loadedIdentity != requestedIdentity { image = nil; loadedIdentity = requestedIdentity }
            failure = false
            guard let url else { failure = image == nil; return }
            // Show any existing tier without generating an intermediate image.
            if image == nil {
                for tier in [dimension] + [960, 480, 1440].filter({ $0 != dimension }) {
                    if let data = await ImageCacheService.shared.existing(asset: asset, dimension: tier), let cached = NSImage(data: data) {
                        guard !Task.isCancelled else { return }
                        image = cached
                        if tier >= dimension { return }
                        break
                    }
                }
            }
            guard !Task.isCancelled else { return }
            if image != nil {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
            let result = await MediaLoader.shared.thumbnail(asset: asset, url: url, maxDimension: dimension)
            guard !Task.isCancelled else { return }
            if let loaded = result.image { image = loaded }
            failure = image == nil
        }
        .onDisappear { image = nil }
    }
}

struct PhotoAspectRatios: PreferenceKey {
    static var defaultValue: [String: Double] = [:]
    static func reduce(value: inout [String: Double], nextValue: () -> [String: Double]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct PhotoView: View {
    @EnvironmentObject var library: LibraryModel
    let asset: Asset
    let url: URL
    var rawURL: URL?
    var compact = false
    var resetID = 0
    @Binding var zoom: Double
    @State private var useRAW = false
    @State private var showOriginal = false
    @State private var editedSource: URL?
    @State private var full = false
    @State private var hdr = true
    @State private var image: NSImage?
    @State private var failure: String?
    private var displayingEdit: Bool { editedSource != nil && !showOriginal }
    private var effectiveHDR: Binding<Bool> { Binding(get: { displayingEdit ? false : hdr }, set: { hdr = $0 }) }
    private var effectiveFull: Binding<Bool> { Binding(get: { displayingEdit ? true : full }, set: { full = $0 }) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if compact {
                    Menu("显示选项") {
                        Toggle("查看原图", isOn: $showOriginal)
                        if rawURL != nil && !asset.preferred.isRAW { Toggle("查看 RAW", isOn: $useRAW) }
                        Toggle("HDR", isOn: effectiveHDR).disabled(displayingEdit)
                        Toggle("原始分辨率", isOn: effectiveFull).disabled(displayingEdit)
                    }.fixedSize()
                } else {
                Text(displayingEdit ? "已编辑 · SDR · " + editedSource!.pathExtension.uppercased() : useRAW || asset.preferred.isRAW || (showOriginal && editedSource.map { Scanner.rawExtensions.contains($0.pathExtension.lowercased()) } == true) ? "RAW 渲染" : "相机直出").font(.caption).foregroundStyle(.secondary)
                Toggle("查看原图", isOn: $showOriginal).toggleStyle(.checkbox)
                if rawURL != nil && !asset.preferred.isRAW { Toggle("查看 RAW", isOn: $useRAW).toggleStyle(.checkbox) }
                Toggle("HDR", isOn: effectiveHDR).disabled(displayingEdit).toggleStyle(.checkbox)
                Toggle("原始分辨率", isOn: effectiveFull).disabled(displayingEdit).toggleStyle(.checkbox)
                }
                Spacer()
                if let image { Text("\(Int(image.size.width)) × \(Int(image.size.height))").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }.font(.caption).padding(10).background(.black.opacity(0.2))
            ZStack {
                Color.black.opacity(0.35)
                if let image { ZoomImage(image: image, zoom: zoom, hdr: effectiveHDR.wrappedValue, resetID: resetID, rotation: asset.quarterTurns) }
                else if let failure { ContentUnavailableView("无法打开原片", systemImage: "externaldrive.badge.exclamationmark", description: Text(failure)) }
                else { ProgressView("正在读取原片…") }
            }
        }
        .preference(key: PhotoAspectRatios.self, value: image.map { [asset.id: asset.quarterTurns % 2 == 0 ? $0.size.width / max(1, $0.size.height) : $0.size.height / max(1, $0.size.width)] } ?? [:])
        .task(id: "\(url.path)|\(useRAW)|\(full)|\(hdr)|\(showOriginal)|\(library.editRevision)|\(asset.quarterTurns)") {
            image = nil; failure = nil
            var source = useRAW ? (rawURL ?? url) : url
            if !showOriginal {
                let edited = await PhotoEditStore.loadPreview(sources: useRAW ? [source] : PhotoEditStore.siblings(asset: asset, preferred: url), thumbnail: false, rotation: asset.quarterTurns)
                guard !Task.isCancelled else { return }
                editedSource = edited.source
                if edited.source != nil { image = edited.image; failure = edited.error; return }
            } else if !useRAW, let editedSource { source = editedSource }
            let result = await MediaLoader.shared.photo(url: source, raw: Scanner.rawExtensions.contains(source.pathExtension.lowercased()), full: full, hdr: hdr, cacheKey: showOriginal && editedSource != nil ? nil : MediaLoader.shared.key(asset: asset, file: asset.files.first(where: { useRAW && $0.isRAW }) ?? asset.preferred))
            guard !Task.isCancelled else { return }
            image = result.image; failure = result.error
        }
    }
}

struct ZoomImage: NSViewRepresentable {
    let image: NSImage
    let zoom: Double
    let hdr: Bool
    var resetID = 0
    var rotation = 0
    var preserveViewport = false
    var onPreviewSize: ((Int) -> Void)? = nil
    func makeNSView(context: Context) -> PhotoScroll {
        let scroll = PhotoScroll(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .overlay; scroll.usesPredominantAxisScrolling = false
        scroll.drawsBackground = false; scroll.allowsMagnification = true; scroll.minMagnification = 1; scroll.maxMagnification = 8
        scroll.documentView = scroll.picture; return scroll
    }
    func updateNSView(_ view: PhotoScroll, context: Context) {
        if view.lastResetID != resetID { view.magnification = 1; view.recenter = true; view.lastResetID = resetID }
        if view.picture.image !== image && !preserveViewport { view.magnification = 1; view.recenter = true }
        if view.picture.rotation != rotation { view.magnification = 1; view.recenter = true; view.picture.rotation = rotation }
        if view.zoom != zoom { view.magnification = 1 }
        view.onPreviewSize = onPreviewSize
        view.picture.image = image; view.picture.preferredImageDynamicRange = hdr ? .high : .standard; view.zoom = zoom; view.needsLayout = true }
}
final class PhotoScroll: NSScrollView {
    let picture = PannableImageView()
    var zoom: Double = 1
    var recenter = true
    var lastResetID = 0
    var onPreviewSize: ((Int) -> Void)?
    private var requestedEdge = 0
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(self, selector: #selector(magnificationChanged), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var magnification: CGFloat { didSet { needsLayout = true } }
    @objc private func magnificationChanged() { needsLayout = true }
    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        needsLayout = true
    }
    override func setMagnification(_ magnification: CGFloat, centeredAt point: NSPoint) {
        super.setMagnification(magnification, centeredAt: point)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        guard let image = picture.image else { return }
        let pixels = picture.rotation % 2 == 0 ? image.size : NSSize(width: image.size.height, height: image.size.width)
        let available = contentSize
        let ratio = min(available.width / max(1, pixels.width), available.height / max(1, pixels.height)) * zoom
        let size = NSSize(width: max(available.width, pixels.width * ratio), height: max(available.height, pixels.height * ratio))
        let scale = window?.backingScaleFactor ?? 2
        let edge = Int(min(max(pixels.width, pixels.height), max(pixels.width, pixels.height) * ratio * magnification * scale))
        let rounded = ((edge + 127) / 128) * 128
        if rounded != requestedEdge {
            requestedEdge = rounded
            DispatchQueue.main.async { [weak self] in self?.onPreviewSize?(rounded) }
        }
        if picture.frame.size != size || recenter {
            let bounds = contentView.bounds
            let oldSize = picture.frame.size
            let center = recenter || oldSize.width == 0 || oldSize.height == 0
                ? NSPoint(x: 0.5, y: 0.5)
                : NSPoint(x: bounds.midX / oldSize.width, y: bounds.midY / oldSize.height)
            picture.frame = NSRect(origin: .zero, size: size)
            let target = NSRect(x: center.x * size.width - bounds.width / 2,
                                y: center.y * size.height - bounds.height / 2,
                                width: bounds.width, height: bounds.height)
            contentView.scroll(to: contentView.constrainBoundsRect(target).origin)
            reflectScrolledClipView(contentView)
            recenter = false
        }
        picture.needsLayout = true
    }
}

final class PannableImageView: NSView {
    private let surface = NSImageView()
    var image: NSImage? { get { surface.image } set { surface.image = newValue; needsLayout = true } }
    var preferredImageDynamicRange: NSImage.DynamicRange {
        get { surface.preferredImageDynamicRange }
        set { surface.preferredImageDynamicRange = newValue }
    }
    var rotation = 0 { didSet { needsLayout = true } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        surface.imageScaling = .scaleProportionallyUpOrDown
        surface.imageAlignment = .alignCenter
        addSubview(surface)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        // Rotate the native HDR surface, never allocate a second full-resolution bitmap.
        surface.frameCenterRotation = 0
        let size = rotation % 2 == 0 ? bounds.size : NSSize(width: bounds.height, height: bounds.width)
        surface.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        surface.frameCenterRotation = -CGFloat(rotation) * 90
    }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    private var lastPoint: NSPoint?
    override func mouseDown(with event: NSEvent) { lastPoint = event.locationInWindow }
    override func mouseDragged(with event: NSEvent) {
        guard let last = lastPoint, let scroll = enclosingScrollView else { return }
        let point = event.locationInWindow
        let factor = scroll.magnification
        let origin = scroll.contentView.bounds.origin
        let deltaY = (point.y - last.y) / factor
        let proposed = NSRect(origin: NSPoint(x: origin.x - (point.x - last.x) / factor,
                                             y: origin.y + (isFlipped ? deltaY : -deltaY)), size: scroll.contentView.bounds.size)
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(proposed).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        lastPoint = point
    }
    override func mouseUp(with event: NSEvent) { lastPoint = nil }
}

extension Notification.Name { static let photoLabPlayback = Notification.Name("PhotoLabPlayback") }
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView { let view = AVPlayerView(); view.controlsStyle = .floating; view.showsFullScreenToggleButton = true; view.player = player; return view }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}
struct VideoView: View {
    let asset: Asset
    let url: URL
    let active: Bool
    @State private var player = AVPlayer()
    @State private var duration = 0.0
    @State private var failure: String?
    @State private var speed: Float = 1
    @State private var playing = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("原始视频 · 不转码", systemImage: "film")
                Spacer()
                Text(duration > 0 ? String(format: "%02d:%02d", Int(duration) / 60, Int(duration) % 60) : "读取中…")
                Picker("速度", selection: $speed) { ForEach([Float(0.5), 1, 1.5, 2], id: \.self) { Text("\($0, specifier: "%.1f")×").tag($0) } }.frame(width: 105)
                Button { player.pause(); playing = false; player.currentItem?.step(byCount: -1) } label: { Image(systemName: "backward.frame") }.help("上一帧 · ⌥←")
                Button { togglePlayback() } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }.help("播放 / 暂停 · 空格")
                Button { player.pause(); playing = false; player.currentItem?.step(byCount: 1) } label: { Image(systemName: "forward.frame") }.help("下一帧 · ⌥→")
            }.font(.caption).padding(10)
            if let failure { ContentUnavailableView("无法播放原片", systemImage: "video.slash", description: Text(failure)) }
            else { PlayerSurface(player: player) }
            Text(active ? "空格播放 / 暂停 · ⌥← / ⌥→ 逐帧 · ← / → 切换素材" : "点击此面板启用声音与键盘控制")
                .font(.caption2).foregroundStyle(.secondary).padding(6)
        }
        .task(id: url) {
            failure = nil; duration = 0
            let source = AVURLAsset(url: url)
            do {
                guard try await source.load(.isPlayable) else { throw CatalogError(message: "系统不支持此视频编码") }
                let time = try await source.load(.duration)
                guard !Task.isCancelled else { return }
                duration = time.seconds.isFinite ? time.seconds : 0
                player.replaceCurrentItem(with: AVPlayerItem(asset: source)); player.isMuted = !active
            } catch { failure = "\(error.localizedDescription)。请确认原盘在线。" }
        }
        .onChange(of: active) { _, newValue in player.isMuted = !newValue }
        .onChange(of: speed) { _, newValue in if player.rate > 0 { player.rate = newValue } }
        .onReceive(NotificationCenter.default.publisher(for: .photoLabPlayback)) { note in
            guard active else { return }
            if let step = note.object as? Int { player.pause(); playing = false; player.currentItem?.step(byCount: step) }
            else { togglePlayback() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { note in
            guard (note.object as? AVPlayerItem) === player.currentItem else { return }
            failure = player.currentItem?.error?.localizedDescription ?? "播放失败，请检查原盘连接"
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in if (note.object as? AVPlayerItem) === player.currentItem { playing = false } }
        .onDisappear { player.pause(); player.replaceCurrentItem(with: nil) }
    }
    private func togglePlayback() {
        if player.rate > 0 { player.pause(); playing = false }
        else { if duration > 0 && player.currentTime().seconds >= duration - 0.1 { player.seek(to: .zero) }; player.playImmediately(atRate: speed); playing = true }
    }
}

func metadata(for asset: Asset, url: URL) async -> [(String, String)] {
    if asset.video {
        let av = AVURLAsset(url: url)
        do {
            let duration = try await av.load(.duration)
            let tracks = try await av.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { return [] }
            let size = try await track.load(.naturalSize); let rate = try await track.load(.nominalFrameRate)
            return [("时长", String(format: "%.2f 秒", duration.seconds)), ("分辨率", "\(Int(size.width)) × \(Int(size.height))"), ("帧率", String(format: "%.2f fps", rate))]
        } catch { return [("状态", "原片离线或暂不支持")] }
    }
    return await withCheckedContinuation { continuation in
        MediaLoader.shared.queue.addOperation {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { continuation.resume(returning: [("状态", "原片离线")]); return }
            let tiff = p[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
            let exif = p[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            func focalLength(_ key: CFString) -> String? {
                guard let value = exif[key as String] as? NSNumber, value.doubleValue.isFinite, value.doubleValue > 0 else { return nil }
                return value.doubleValue.formatted(.number.precision(.fractionLength(0...2))) + " mm"
            }
            var pairs: [(String, String)] = []
            if let w = p[kCGImagePropertyPixelWidth as String], let h = p[kCGImagePropertyPixelHeight as String] { pairs.append(("分辨率", "\(w) × \(h)")) }
            for (label, value) in [("相机", tiff["Model"]), ("镜头", exif["LensModel"]), ("焦距", focalLength(kCGImagePropertyExifFocalLength)), ("35mm 等效焦距", focalLength(kCGImagePropertyExifFocalLenIn35mmFilm)), ("拍摄时间", exif["DateTimeOriginal"]), ("光圈", exif["FNumber"]), ("曝光时间", (exif["ExposureTime"] as? NSNumber).map { ExposureFormatting.string(seconds: $0.doubleValue) }), ("色彩空间", p["ProfileName"])] {
                if let value { pairs.append((label, "\(value)")) }
            }
            continuation.resume(returning: pairs)
        }
    }
}


func captureDate(for asset: Asset, urls: [URL]) async -> Double? {
    if !asset.video {
        return await Task.detached(priority: .utility) { CaptureDates.readPhoto(urls) }.value
    }
    guard let url = urls.first else { return nil }
    let video = AVURLAsset(url: url)
    if let item = try? await video.load(.creationDate), let date = try? await item.load(.dateValue) { return date.timeIntervalSince1970 }
    return nil
}
