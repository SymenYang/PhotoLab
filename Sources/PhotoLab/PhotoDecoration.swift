import AppKit
import CoreImage
import CoreText
import ImageIO

// Presentation is independent of the color recipe. Assets are embedded in the
// sidecar so moving a photo never breaks its stickers or relies on import paths.
enum PhotoFrameStyle: String, Codable, CaseIterable, Identifiable {
    case none, gallery, galleryDark, reportage, reportageDark, paper, cream, instant, film
    static let borders: [Self] = [.none, .paper, .cream, .instant, .film]
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "无边框"
        case .gallery: return "画廊白"
        case .galleryDark: return "画廊黑"
        case .reportage: return "纪实白"
        case .reportageDark: return "纪实黑"
        case .paper: return "纯色边框"
        case .cream: return "棉纸纹理"
        case .instant: return "即影相纸"
        case .film: return "胶片片边"
        }
    }
    var dark: Bool { self == .galleryDark || self == .reportageDark || self == .film }
    var information: Bool { [.gallery, .galleryDark, .reportage, .reportageDark].contains(self) }
    var textured: Bool { self == .cream || self == .instant }
}
enum StickerFont: String, Codable, CaseIterable {
    case helvetica, sans, serif, hand
    var title: String { switch self { case .helvetica: return "Helvetica"; case .sans: return "系统"; case .serif: return "衬线"; case .hand: return "手写" } }
    func font(_ size: CGFloat) -> NSFont {
        switch self {
        case .helvetica: return NSFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
        case .sans: return .systemFont(ofSize: size, weight: .medium)
        case .serif: return NSFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size)
        case .hand: return NSFont(name: "Noteworthy", size: size) ?? .systemFont(ofSize: size)
        }
    }
}
struct PhotoSticker: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name = "文字"
    var kind = "text"
    var data: Data?
    var text = "写下这一刻"
    var font = StickerFont.helvetica
    var color = "222222"
    // Centers are normalized in the final, upright presentation canvas.
    var x = 0.5
    var y = 0.85
    var width = 0.28
    var aspect = 1.0
    var angle = 0.0
    var opacity = 1.0
    var hidden = false
    var field: String? // EXIF binding; nil is freely editable literal text.
    var omitCameraBrand: Bool? // Information presets show the model beside a separate logo.
    var logoID: String? // "auto" or a bundled logo ID; all render as ordinary SVG stickers.
    var logoMaxHeight: Double?
    var logoVariant: String?
    var templateSlot: String?
    var textSize: Double? // Font size as a fraction of the canvas short edge.
    var textBoxWidth: Double? // Legacy preset column; migrated to measured bounds.
    var alignment: String? = "center"
    func resolved(_ metadata: FrameMetadata) -> Self {
        var value = self
        if let field { value.text = field == "camera" && omitCameraBrand == true ? metadata.cameraModel : metadata.value(field) }
        if let logoID {
            let id = logoID == "auto" ? metadata.brand?.rawValue : logoID
            if let id, let asset = try? BrandStickerCatalog.sticker(id, variant: logoVariant ?? "black") {
                value.data = asset.data; value.aspect = asset.aspect
            } else { value.data = nil }
        }
        return value
    }
}
struct PhotoDecoration: Codable, Equatable {
    var layoutVersion: Int? = 2
    var style = PhotoFrameStyle.none
    // nil means automatic. Optional for existing sidecars and saved presets.
    var brandLogo: String?
    func logoBrand(for metadata: FrameMetadata) -> CameraBrand? {
        if let brandLogo { return CameraBrand(rawValue: brandLogo) }
        return metadata.brand
    }
    var background: String?
    var backgroundHex: String { background ?? (style.dark ? "141414" : style.textured ? "F6F1E7" : "FFFFFF") }
    var darkBackground: Bool {
        let n = UInt32(backgroundHex, radix: 16) ?? 0xFFFFFF
        return (Double((n >> 16) & 255)*0.2126 + Double((n >> 8) & 255)*0.7152 + Double(n & 255)*0.0722) < 140
    }
    var margin = 0.045
    var footer = 0.16
    var ratio = "自动"
    var texture = 0.22
    var photoShadow: Bool? // Missing in older sidecars; off until enabled.
    var signature = ""
    var showCamera = true
    var showLens = true
    var showSettings = true
    var showDate = false
    var stickers: [PhotoSticker] = []
    var hasContent: Bool { style != .none || !stickers.isEmpty }
    var active: Bool { style != .none || stickers.contains { !$0.hidden } }
    func validate() throws {
        if let brandLogo, brandLogo != "none", CameraBrand(rawValue: brandLogo) == nil { throw CatalogError(message: "相机 Logo 无效") }
        guard margin.isFinite, (0.01...0.18).contains(margin), footer.isFinite, (0...0.35).contains(footer),
              texture.isFinite, (0...1).contains(texture), ["自动", "1:1", "4:5", "3:2", "2:3", "16:9"].contains(ratio),
              signature.count <= 120, stickers.count <= 48,
              Set(stickers.map(\.id)).count == stickers.count,
              stickers.reduce(0, { $0 + ($1.data?.count ?? 0) }) <= 24_000_000 else { throw CatalogError(message: "边框或贴纸参数超出限制") }
        if let background { guard background.count == 6, UInt32(background, radix: 16) != nil else { throw CatalogError(message: "边框颜色无效") } }
        for s in stickers {
            guard [s.x, s.y, s.width, s.aspect, s.angle, s.opacity].allSatisfy(\.isFinite),
                  (0...1).contains(s.x), (0...1).contains(s.y), (0.005...1).contains(s.width), (0.01...100).contains(s.aspect),
                  (-180...180).contains(s.angle), (0...1).contains(s.opacity), s.text.count <= 500,
                  s.color.count == 6, UInt32(s.color, radix: 16) != nil, ["text", "png", "svg"].contains(s.kind) else { throw CatalogError(message: "贴纸参数无效") }
            if let field = s.field, !FrameMetadata.fields.contains(field) { throw CatalogError(message: "贴纸信息字段无效") }
            if let id = s.logoID, id != "auto", !BrandStickerCatalog.ids.contains(id) { throw CatalogError(message: "Logo 贴纸无效") }
            if let variant = s.logoVariant, !BrandStickerCatalog.variants.contains(variant) { throw CatalogError(message: "Logo 颜色无效") }
            if let height = s.logoMaxHeight, !height.isFinite || !(0.005...1).contains(height) { throw CatalogError(message: "Logo 高度无效") }
            if let size = s.textSize, !size.isFinite || !(0.003...0.5).contains(size) { throw CatalogError(message: "文字大小无效") }
            if let width = s.textBoxWidth, !width.isFinite || !(0.01...1).contains(width) { throw CatalogError(message: "文字宽度无效") }
            if let alignment = s.alignment, !["left", "center", "right"].contains(alignment) { throw CatalogError(message: "文字对齐无效") }
            if s.kind != "text", s.logoID != "auto" {
                guard let data = s.data, !data.isEmpty, data.count <= 8_000_000 else { throw CatalogError(message: "贴纸文件为空或大于 8 MB") }
                if s.kind == "svg" { try StickerImport.validateSVG(data) }
                else { try StickerImport.validatePNG(data) }
            }
        }
    }
}
struct FrameMetadata: Codable, Equatable {
    var camera = ""
    var lens = ""
    var settings = ""
    var date = ""
    var make: String?
    var model: String?
    var brand: CameraBrand? { CameraBrand.identify(make: make, model: model ?? camera) }
    var cameraModel: String {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "·:"))
        let value = (model?.isEmpty == false ? model! : camera).trimmingCharacters(in: separators)
        var prefixes = [make ?? ""]
        if let brand { prefixes.append(brand.rawValue.replacingOccurrences(of: "-", with: " ")) }
        for prefix in prefixes.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            guard let range = value.range(of: prefix, options: [.anchored, .caseInsensitive]) else { continue }
            let rest = String(value[range.upperBound...])
            guard rest.isEmpty || rest.unicodeScalars.first.map({ separators.contains($0) }) == true else { continue }
            return rest.trimmingCharacters(in: separators)
        }
        return value
    }
    static let fields = ["camera", "lens", "settings", "date"]
    func value(_ field: String) -> String {
        switch field { case "camera": return camera; case "lens": return lens; case "settings": return settings; case "date": return date; default: return "" }
    }
    static func read(_ url: URL) -> Self {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return Self() }
        let t = p[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let e = p[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        var fields: [String] = []
        if let n = e[kCGImagePropertyExifFocalLength as String] as? NSNumber { fields.append(n.doubleValue.formatted(.number.precision(.fractionLength(0...1))) + " mm") }
        if let n = e[kCGImagePropertyExifFNumber as String] as? NSNumber { fields.append("f/" + n.doubleValue.formatted(.number.precision(.fractionLength(0...1)))) }
        if let n = e[kCGImagePropertyExifExposureTime as String] as? NSNumber, n.doubleValue > 0 {
            fields.append(n.doubleValue < 1 ? "1/\(Int((1 / n.doubleValue).rounded())) s" : n.doubleValue.formatted(.number.precision(.fractionLength(0...2))) + " s")
        }
        if let n = (e[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first { fields.append("ISO \(n)") }
        let date = (e[kCGImagePropertyExifDateTimeOriginal as String] as? String).map { String($0.prefix(10)).replacingOccurrences(of: ":", with: ".") } ?? ""
        let model = t[kCGImagePropertyTIFFModel as String] as? String ?? ""
        let make = (t[kCGImagePropertyTIFFMake as String] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let camera = !make.isEmpty && !model.localizedCaseInsensitiveContains(make) ? [make, model].filter { !$0.isEmpty }.joined(separator: " · ") : model
        return Self(camera: camera, lens: e[kCGImagePropertyExifLensModel as String] as? String ?? "", settings: fields.joined(separator: "   ·   "), date: date, make: make, model: model)
    }
}

enum CameraBrand: String, CaseIterable {
    case hasselblad, leica, sony, canon, nikon, fujifilm, panasonic, olympus
    case omSystem = "om-system"
    case ricoh, pentax, sigma, dji
    var title: String {
        switch self {
        case .hasselblad: return "Hasselblad · 哈苏"
        case .leica: return "Leica · 徕卡"
        case .sony: return "Sony · 索尼"
        case .canon: return "Canon · 佳能"
        case .nikon: return "Nikon · 尼康"
        case .fujifilm: return "Fujifilm · 富士"
        case .panasonic: return "Panasonic · 松下"
        case .olympus: return "Olympus · 奥林巴斯"
        case .omSystem: return "OM SYSTEM"
        case .ricoh: return "Ricoh · 理光"
        case .pentax: return "Pentax · 宾得"
        case .sigma: return "Sigma · 适马"
        case .dji: return "DJI · 大疆"
        }
    }
    static func identify(make: String?, model: String) -> Self? {
        func words(_ value: String) -> String {
            " " + value.uppercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ") + " "
        }
        let manufacturer = words(make ?? ""), model = words(model)
        // Make wins over Model; a lens brand must never determine the camera.
        let source = manufacturer.trimmingCharacters(in: .whitespaces).isEmpty ? model : manufacturer
        func has(_ token: String) -> Bool { source.contains(" " + token + " ") }
        if has("RICOH") { return model.contains(" PENTAX ") ? .pentax : .ricoh }
        if has("OM DIGITAL SOLUTIONS") || has("OM SYSTEM") { return .omSystem }
        if has("FUJIFILM") || has("FUJI PHOTO FILM") { return .fujifilm }
        if has("LUMIX") { return .panasonic }
        if has("ASAHI OPTICAL") { return .pentax }
        return allCases.first { $0 != .omSystem && has($0.rawValue.uppercased()) }
    }
}

// SVGs remain vector data. No scripts, remote files or embedded HTML are needed
// for a sticker; reject these before handing the document to AppKit's SVG rep.
enum StickerImport {
    static func validatePNG(_ data: Data) throws {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetType(src) as String? == "public.png",
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let w = p[kCGImagePropertyPixelWidth as String] as? Int, let h = p[kCGImagePropertyPixelHeight as String] as? Int,
              w > 0, h > 0, w <= 16384, h <= 16384, w * h <= 32_000_000 else { throw CatalogError(message: "PNG 无效或超过 3200 万像素") }
    }
    static func validateSVG(_ data: Data) throws {
        guard data.count <= 2_000_000, let text = String(data: data, encoding: .utf8) else { throw CatalogError(message: "SVG 需为 UTF-8，大小不超过 2 MB") }
        let lower = text.lowercased()
        guard !lower.contains("<!doctype"), !lower.contains("<!entity"), !lower.contains("@import"), !lower.contains("\\") else { throw CatalogError(message: "SVG 包含不支持的外部资源或样式") }
        let check = SVGStickerValidator()
        check.checkURLs(text)
        let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = check
        guard parser.parse(), check.valid, check.root == "svg" else { throw CatalogError(message: "SVG 需为静态图形；请移除脚本、外链、动画和嵌入图片") }
    }
    static func load(_ url: URL) throws -> PhotoSticker {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 8_000_000 else { throw CatalogError(message: "贴纸文件需小于 8 MB") }
        let data = try Data(contentsOf: url), ext = url.pathExtension.lowercased()
        if ext == "svg" { try validateSVG(data) }
        else if ext == "png" { try validatePNG(data) }
        else { throw CatalogError(message: "请选择 PNG 或 SVG 文件") }
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { throw CatalogError(message: "无法解码贴纸") }
        var s = PhotoSticker(); s.name = url.deletingPathExtension().lastPathComponent; s.kind = ext; s.data = data
        s.aspect = image.size.width / image.size.height; s.y = 0.8
        guard (0.01...100).contains(s.aspect) else { throw CatalogError(message: "贴纸长宽比超出支持范围") }
        return s
    }
}
private final class SVGStickerValidator: NSObject, XMLParserDelegate {
    var valid = true
    var root: String?
    private let allowed: Set<String> = ["svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "defs", "lineargradient", "radialgradient", "stop", "clippath", "mask", "pattern", "use", "symbol", "title", "desc", "text", "tspan", "style"]
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if root == nil { root = elementName.lowercased() }
        if !allowed.contains(elementName.lowercased()) { valid = false }
        for (key, value) in attributes {
            if key.lowercased().hasPrefix("on") { valid = false }
            if key.lowercased().hasSuffix("href"), !value.hasPrefix("#") { valid = false }
            checkURLs(value)
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { checkURLs(string) }
    func checkURLs(_ value: String) {
        if value.lowercased().contains("@import") || value.contains("\\") { valid = false }
        let regex = try! NSRegularExpression(pattern: "url\\s*\\(([^)]*)\\)", options: .caseInsensitive)
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            let ref = (value as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
            if !ref.hasPrefix("#") { valid = false }
        }
    }
}
struct DecorationLayout {
    var size: CGSize
    var photo: CGRect // Top-left coordinates, like the interactive canvas.
    static func make(photo: CGSize, decoration d: PhotoDecoration) -> Self {
        guard d.style != .none else { return Self(size: photo, photo: CGRect(origin: .zero, size: photo)) }
        let unit = min(photo.width, photo.height), m = unit * d.margin
        let bottom = d.layoutVersion == 2 || d.style.information || d.style == .instant ? max(m, unit * d.footer) : m
        var w = ceil(photo.width + 2*m), h = ceil(photo.height + m + bottom)
        let ratios: [String: CGFloat] = ["1:1": 1, "4:5": 0.8, "3:2": 1.5, "2:3": 2/3, "16:9": 16/9]
        if let ratio = ratios[d.ratio] { if w/h < ratio { w = ceil(h*ratio) } else { h = ceil(w/ratio) } }
        return Self(size: CGSize(width: w, height: h), photo: CGRect(x: (w-photo.width)/2, y: (h-photo.height-bottom+m)/2, width: photo.width, height: photo.height))
    }
}
enum PhotoDecorationRenderer {
    // AppKit image reps are not shared across threads. Serial drawing also keeps
    // peak full-resolution overlay allocations bounded during batch exports.
    private static let lock = NSRecursiveLock()
    static func resource(_ name: String) -> URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Decorations").appendingPathComponent(name)
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Decorations").appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: development.path) ? development : nil
    }
    static func rotate(_ input: CIImage, _ turns: Int) -> CIImage {
        let image = turns == 0 ? input : input.oriented(turns == 1 ? .right : turns == 2 ? .down : .left)
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
    static func textAttributes(_ s: PhotoSticker, canvas: CGSize) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byClipping
        return [.font: s.font.font(min(canvas.width, canvas.height) * (s.textSize ?? s.width*0.16)), .foregroundColor: color(s.color), .paragraphStyle: paragraph]
    }
    static func stickerRect(_ s: PhotoSticker, canvas: CGSize) -> CGRect {
        let size: CGSize
        if s.kind == "text" {
            let measured = ((s.text.isEmpty ? " " : s.text) as NSString).size(withAttributes: textAttributes(s, canvas: canvas))
            size = measured
        }
        else {
            let width = min(canvas.width*s.width, s.logoMaxHeight.map { canvas.height*$0*s.aspect } ?? .greatestFiniteMagnitude)
            size = CGSize(width: width, height: width/s.aspect)
        }
        return CGRect(x: canvas.width*s.x-size.width/2, y: canvas.height*s.y-size.height/2, width: max(1,size.width), height: max(1,size.height))
    }
    static func color(_ hex: String) -> NSColor {
        let n = UInt32(hex, radix: 16) ?? 0x222222
        return NSColor(srgbRed: CGFloat((n >> 16) & 255)/255, green: CGFloat((n >> 8) & 255)/255, blue: CGFloat(n & 255)/255, alpha: 1)
    }
    // Returned pixels keep the caller's original orientation. Existing thumbnail
    // and viewer rotation can then be applied exactly once, with upright labels.
    static func compose(_ input: CIImage, decoration d: PhotoDecoration?, metadata: FrameMetadata, rotation: Int = 0) throws -> CIImage {
        try Task.checkCancellation()
        guard let original = d, original.active else { return input }
        let upright = rotate(input, rotation)
        let d = original.migrated(metadata: metadata, photo: upright.extent.size)
        try d.validate()
        lock.lock(); defer { lock.unlock() }
        try Task.checkCancellation()
        let photo = rotate(input, rotation), layout = DecorationLayout.make(photo: photo.extent.size, decoration: d)
        let size = layout.size, rect = layout.photo
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0, w <= 40000, h <= 40000, Double(w)*Double(h) <= 200_000_000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CatalogError(message: "装饰画布过大，请减小边框或使用自动比例") }
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let full = CGRect(origin: .zero, size: size)
        if d.style != .none {
            let bg = d.backgroundHex
            ctx.setFillColor(color(bg).cgColor); ctx.fill(full)
            if d.style.textured, d.texture > 0, let url = resource("Paper001_Color.jpg"), let texture = NSImage(contentsOf: url) {
                ctx.saveGState(); ctx.setAlpha(d.texture); ctx.setBlendMode(.multiply)
                // Texture scale follows the photo, so preview and export match.
                let tile = min(rect.width, rect.height) * 0.65
                for y in stride(from: CGFloat(0), to: size.height, by: tile) {
                    try Task.checkCancellation()
                    for x in stride(from: CGFloat(0), to: size.width, by: tile) {
                    texture.draw(in: CGRect(x: x, y: y, width: tile, height: tile), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                } }
                ctx.restoreGState()
            }
            if d.photoShadow == true {
                // Draw into the border overlay, then clear the photo opening so
                // the original photo pixels and HDR values remain untouched.
                let unit = min(rect.width, rect.height)
                let edge = min(rect.minX, rect.minY, size.width-rect.maxX, size.height-rect.maxY)
                ctx.saveGState()
                // Quartz shadow offsets do not follow the flipped canvas transform.
                ctx.setShadow(offset: CGSize(width: 0, height: -min(unit*0.008,edge*0.16)),
                              blur: min(unit*0.024,edge*0.5), color: CGColor(gray: 0, alpha: 0.32))
                ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(rect)
                ctx.restoreGState()
            }
            ctx.clear(rect)
            drawFrame(d, layout: layout, context: ctx)
        }
        for original in d.stickers where !original.hidden {
            try Task.checkCancellation()
            let s = original.resolved(metadata)
            if s.kind != "text", s.data == nil, s.logoID == "auto" { continue }
            let r = stickerRect(s, canvas: size)
            ctx.saveGState(); ctx.setAlpha(s.opacity); ctx.translateBy(x: r.midX, y: r.midY); ctx.rotate(by: s.angle * .pi / 180)
            let local = CGRect(x: -r.width/2, y: -r.height/2, width: r.width, height: r.height)
            if s.kind == "text" { (s.text as NSString).draw(in: local, withAttributes: textAttributes(s, canvas: size)) }
            else if let data = s.data, let image = NSImage(data: data) {
                image.draw(in: local, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            } else { throw CatalogError(message: "贴纸无法绘制：\(s.name)") }
            ctx.restoreGState()
        }
        guard let overlay = ctx.makeImage() else { throw CatalogError(message: "无法创建装饰图层") }
        let placed = photo.transformed(by: CGAffineTransform(translationX: rect.minX, y: size.height-rect.maxY))
        let result = CIImage(cgImage: overlay).composited(over: placed).cropped(to: full)
        return rotate(result, (4-rotation)%4)
    }
    private static func drawFrame(_ d: PhotoDecoration, layout l: DecorationLayout, context ctx: CGContext) {
        guard d.style == .film else { return }
        let r = l.photo, hole = max(1, r.minX*0.3), step = hole*2.7
        ctx.setFillColor(color("D8D1BD").cgColor)
        for y in stride(from: r.minY+hole, to: r.maxY-hole, by: step) {
            for x in [r.minX*0.3, l.size.width-r.minX*0.3-hole] { ctx.fill(CGRect(x: x, y: y, width: hole, height: hole*1.45)) }
        }
    }
}

// Templates create ordinary, independently editable stickers. Bindings stay live
// across a batch/preset until the user types their own text or selects a brand.
enum BrandStickerCatalog {
    static let ids = CameraBrand.allCases.map(\.rawValue) + ["hasselblad-symbol", "leica-wordmark"]
    static let variants = ["original", "black", "white"]
    static func title(_ id: String) -> String {
        if id == "auto" { return "自动相机 Logo" }
        if id == "hasselblad-symbol" { return "哈苏 H 符号" }
        if id == "leica-wordmark" { return "徕卡字标" }
        return CameraBrand(rawValue: id)?.title ?? id
    }
    static func sticker(_ id: String, variant: String) throws -> PhotoSticker {
        guard ids.contains(id), variants.contains(variant),
              let url = PhotoDecorationRenderer.resource("Brands/Variants/\(id)-\(variant).svg") else { throw CatalogError(message: "Logo 素材缺失") }
        var s = try StickerImport.load(url)
        s.logoID = id; s.logoVariant = variant; s.name = title(id); s.width = 0.18; s.y = 0.9
        return s
    }
}
extension PhotoDecoration {
    func migrated(metadata: FrameMetadata, photo: CGSize) -> Self {
        guard layoutVersion != 2 else { return tightTextLayout(metadata: metadata, photo: photo) }
        var value = self
        // Preserve the old canvas geometry while replacing its implicit labels.
        if !style.information && style != .instant { value.footer = margin }
        value.layoutVersion = 2
        if style.information {
            value.addInformationPreset(style == .reportage || style == .reportageDark ? "split" : "info", metadata: metadata, photo: photo)
            value.stickers.removeAll { s in
                (s.field == "camera" && !showCamera) || (s.field == "lens" && !showLens) || (s.field == "settings" && !showSettings) || (s.logoID != nil && brandLogo == "none")
            }
            if let brandLogo, brandLogo != "none", let i = value.stickers.firstIndex(where: { $0.logoID == "auto" }) {
                value.stickers[i].logoID = brandLogo
            }
        } else if style != .none && (!signature.isEmpty || showDate || style == .film) {
            value.addInformationPreset("caption", metadata: metadata, photo: photo)
            if signature.isEmpty {
                if style == .film { value.stickers.firstIndex(where: { $0.templateSlot == "签名" }).map { value.stickers[$0].text = "FRAME 01" } }
                else { value.stickers.removeAll { $0.templateSlot == "签名" } }
            }
        }
        if style.information { value.background = backgroundHex; value.style = .paper }
        return value.tightTextLayout(metadata: metadata, photo: photo)
    }
    private func tightTextLayout(metadata: FrameMetadata, photo: CGSize) -> Self {
        var value = self
        let canvas = DecorationLayout.make(photo: photo, decoration: self).size
        for i in value.stickers.indices where value.stickers[i].kind == "text" {
            var s = value.stickers[i]
            if let oldWidth = s.textBoxWidth {
                let width = PhotoDecorationRenderer.stickerRect(s.resolved(metadata), canvas: canvas).width
                // Keep the old visible text anchor when removing a preset column.
                let offset = s.alignment == "center" ? 0 : (width - oldWidth*canvas.width)/2 * (s.alignment == "right" ? -1 : 1)
                let angle = s.angle * .pi/180
                s.x = min(1,max(0,s.x + offset*cos(angle)/canvas.width))
                s.y = min(1,max(0,s.y + offset*sin(angle)/canvas.height))
            }
            s.textBoxWidth = nil; s.alignment = "center"
            value.stickers[i] = s
        }
        return value
    }
    mutating func addInformationPreset(_ template: String, metadata: FrameMetadata, photo: CGSize) {
        stickers.removeAll { $0.templateSlot != nil }
        let layout = DecorationLayout.make(photo: photo, decoration: self), canvas = layout.size, r = layout.photo
        let short = min(canvas.width, canvas.height), unit = min(r.width, r.height)
        let bottom = style == .none ? r.height*0.2 : canvas.height-r.maxY
        let top = style == .none ? r.height*0.78 : r.maxY
        let ink = darkBackground || style == .none ? "F4F0E6" : "222222"
        func informationSize(_ size: CGFloat, widths: [CGFloat]) -> CGFloat {
            zip([metadata.cameraModel, metadata.lens, metadata.settings], widths).reduce(size) { fitted, row in
                var s = PhotoSticker(); s.text = row.0; s.textSize = size/short
                let measured = PhotoDecorationRenderer.stickerRect(s, canvas: canvas).width
                return min(fitted, size * min(1,row.1/measured))
            }
        }
        func text(_ slot: String, field: String? = nil, literal: String = "", x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat, alignment: String = "left", font: StickerFont = .helvetica) -> PhotoSticker {
            var s = PhotoSticker(); s.id = "preset-"+slot; s.templateSlot = slot; s.name = slot
            s.field = field; s.omitCameraBrand = field == "camera" ? true : nil
            s.text = field == "camera" ? metadata.cameraModel : field.map { metadata.value($0) } ?? literal; s.color = ink; s.font = font
            s.textSize = max(0.003,size/short); s.alignment = "center"
            let measured = PhotoDecorationRenderer.stickerRect(s, canvas: canvas).width
            // These three fields were fitted as a group; keep their font sizes equal.
            if !["camera","lens","settings"].contains(field ?? ""), measured > width { s.textSize = max(0.003,s.textSize!*width/measured) }
            let fitted = PhotoDecorationRenderer.stickerRect(s, canvas: canvas).width
            let center = alignment == "center" ? x+width/2 : alignment == "right" ? x+width-fitted/2 : x+fitted/2
            s.x = min(1,max(0,center/canvas.width)); s.y = y/canvas.height
            return s
        }
        var created: [PhotoSticker] = []
        if template == "caption" {
            created.append(text("签名", literal: signature.isEmpty ? "写下这一刻" : signature, x:r.minX, y:top+bottom*0.43, width:r.width, size:min(unit*0.035,bottom*0.3), alignment:"center", font:.hand))
        } else {
            var logo = (try? BrandStickerCatalog.sticker(metadata.brand?.rawValue ?? "hasselblad", variant: darkBackground || style == .none ? "white" : "black")) ?? PhotoSticker()
            logo.id = "preset-logo"; logo.templateSlot = "logo"; logo.name = "相机 Logo"; logo.logoID = "auto"; logo.kind = "svg"
            logo.width = unit*0.22/canvas.width; logo.x = (r.minX+unit*0.11)/canvas.width; logo.y = (top+bottom*0.48)/canvas.height
            logo.logoMaxHeight = max(0.005,bottom*0.52/canvas.height)
            if template == "center" {
                logo.x = r.midX/canvas.width; logo.y = (top+bottom*0.17)/canvas.height
                logo.width = unit*0.18/canvas.width; logo.logoMaxHeight = max(0.005,bottom*0.2/canvas.height)
                created.append(logo)
                var rows: [(String,String?,String)] = [("相机","camera",""),("镜头","lens",""),("拍摄参数","settings","")]
                if !signature.isEmpty { rows.append(("签名",nil,signature)) }
                if showDate { rows.append(("日期","date","")) }
                let step = min(0.18,0.5/Double(max(1,rows.count-1)))
                let size = informationSize(min(unit*0.023,bottom*min(0.13,step*0.65)), widths: [r.width,r.width,r.width])
                for (i,row) in rows.enumerated() {
                    created.append(text(row.0,field:row.1,literal:row.2,x:r.minX,y:top+bottom*(0.4+Double(i)*step),width:r.width,size:size,alignment:"center",font:row.0 == "签名" ? .serif:.helvetica))
                }
            } else {
            created.append(logo)
            let x = r.minX+unit*0.27, width = r.maxX-x
            let leftWidth = width*(template == "split" ? 0.52 : 1), rightWidth = width*(template == "split" ? 0.46 : 1)
            let size = informationSize(min(unit*0.023,bottom*0.14),widths:[leftWidth,leftWidth,rightWidth])
            created.append(text("相机",field:"camera",x:x,y:top+bottom*0.30,width:leftWidth,size:size))
            created.append(text("镜头",field:"lens",x:x,y:top+bottom*0.48,width:leftWidth,size:size))
            created.append(text("拍摄参数",field:"settings",x:template == "split" ? x+width*0.54 : x,y:top+bottom*(template == "split" ? 0.30 : 0.66),width:rightWidth,size:size,alignment:template == "split" ? "right":"left"))
            if !signature.isEmpty { created.append(text("签名",literal:signature,x:x+width*0.55,y:top+bottom*0.65,width:width*0.45,size:size*0.8,alignment:"right",font:.serif)) }
        }
        }
        if showDate && template != "center" { created.append(text("日期",field:"date",x:r.minX+r.width*0.6,y:top+bottom*0.83,width:r.width*0.4,size:unit*0.012,alignment:"right")) }
        stickers.append(contentsOf: created.prefix(max(0,48-stickers.count)))
    }
}

enum StickerTransform {
    // Thresholds are screen points so snapping feels the same at every zoom.
    // A wider release threshold avoids flicker while following the guide.
    static func snapped(_ sticker: PhotoSticker, canvas: CGSize, holdingX: Bool = false, holdingY: Bool = false) -> (sticker: PhotoSticker, x: Bool, y: Bool) {
        var result = sticker
        let x = abs(sticker.x-0.5)*canvas.width <= (holdingX ? 10 : 6)
        let y = abs(sticker.y-0.5)*canvas.height <= (holdingY ? 10 : 6)
        if x { result.x = 0.5 }
        if y { result.y = 0.5 }
        return (result,x,y)
    }

    static func hit(_ point: CGPoint, stickers: [PhotoSticker], selectedID: String?, metadata: FrameMetadata, canvas: CGSize) -> (sticker: PhotoSticker, mode: String)? {
        if let s = stickers.first(where: { $0.id == selectedID && !$0.hidden }) {
            let r = PhotoDecorationRenderer.stickerRect(s.resolved(metadata),canvas:canvas)
            for rotating in [true,false] {
                let p = handle(CGPoint(x:r.midX,y:r.midY),size:r.size,angle:s.angle,rotation:rotating)
                if hypot(point.x-p.x,point.y-p.y) <= 18 { return (s,rotating ? "rotate":"scale") }
            }
        }
        for s in stickers.reversed() where !s.hidden {
            let resolved = s.resolved(metadata)
            if s.logoID == "auto" && resolved.data == nil { continue }
            let r = PhotoDecorationRenderer.stickerRect(resolved,canvas:canvas), a = -s.angle * .pi/180
            let x = point.x-r.midX, y = point.y-r.midY
            if abs(x*cos(a)-y*sin(a)) <= max(6,r.width/2) && abs(x*sin(a)+y*cos(a)) <= max(6,r.height/2) { return (s,"move") }
        }
        return nil
    }
    static func scaled(_ s: PhotoSticker, by scale: Double) -> PhotoSticker {
        var result = s
        let factor: Double
        if s.kind == "text" {
            let size = s.textSize ?? s.width*0.16
            result.textSize = min(0.5,max(0.003,size*scale))
            factor = result.textSize!/max(0.00001,size)
        } else {
            factor = min(1/max(0.005,s.width),max(0.005/max(0.005,s.width),scale))
        }
        result.width = min(1,max(0.005,s.width*factor))
        if let size = s.textSize { result.textSize = min(0.5,max(0.003,size*factor)) }
        if let width = s.textBoxWidth { result.textBoxWidth = min(1,max(0.01,width*factor)) }
        if let height = s.logoMaxHeight { result.logoMaxHeight = min(1,max(0.005,height*factor)) }
        return result
    }
    static func angle(_ degrees: Double) -> Double {
        let value = (degrees+180).truncatingRemainder(dividingBy:360)
        return (value < 0 ? value+360 : value)-180
    }
    static func handle(_ center: CGPoint, size: CGSize, angle: Double, rotation: Bool) -> CGPoint {
        let offset = rotation ? CGPoint(x:0,y:-size.height/2-26) : CGPoint(x:size.width/2,y:size.height/2)
        let a = angle * .pi/180
        return CGPoint(x:center.x+offset.x*cos(a)-offset.y*sin(a),y:center.y+offset.x*sin(a)+offset.y*cos(a))
    }
}
