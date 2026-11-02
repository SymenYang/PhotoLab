import AppKit
import CoreImage
import ImageIO

func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw CatalogError(message: message) }
}
@main struct DecorationTests {
    static func png(_ cg: CGImage, _ url: URL, metadata: CFDictionary? = nil) throws {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, metadata)
        try check(CGImageDestinationFinalize(dest), "write PNG")
    }
    static func bitmap(_ image: CIImage) throws -> CGImage { try PhotoEditStore.cgImage(image) }
    static func digest(_ image: CIImage) throws -> Data { let cg = try bitmap(image); return cg.dataProvider!.data! as Data }
    static func cacheBytes(_ source: URL) throws -> Data {
        let e = try PhotoEditStore.read(source)!
        let file = try FileHandle(forReadingFrom: PhotoEditStore.sidecar(source)); defer { try? file.close() }
        try file.seek(toOffset: e.payloadOffset)
        return try file.read(upToCount: e.document.tiffBytes)!
    }
    static func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<300 { if await condition() { return }; try await Task.sleep(for: .milliseconds(30)) }
        throw CatalogError(message: "editor wait timed out")
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PHOTOLAB_DATA_DIR"]!).appendingPathComponent("fixtures")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("photo.tiff")
        let base = CIImage(color: CIColor(red: 0.12, green: 0.37, blue: 0.62)).cropped(to: CGRect(x: 0, y: 0, width: 600, height: 400))
        let props: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Hasselblad", kCGImagePropertyTIFFModel: "Hasselblad X2D 100C"], kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "XCD 55V", kCGImagePropertyExifFocalLength: 55, kCGImagePropertyExifFNumber: 2.5, kCGImagePropertyExifExposureTime: 1.0/125, kCGImagePropertyExifISOSpeedRatings: [400], kCGImagePropertyExifDateTimeOriginal: "2026:10:30 12:00:00"]]
        let sourceWriter = CGImageDestinationCreateWithURL(source as CFURL, "public.tiff" as CFString, 1, nil)!
        CGImageDestinationAddImage(sourceWriter, try bitmap(base), props as CFDictionary)
        try check(CGImageDestinationFinalize(sourceWriter), "source fixture")
        let original = try Data(contentsOf: source)
        let metadata = FrameMetadata.read(source)
        try check(PhotoSticker().font.font(24).fontName == "Helvetica", "new text must default to Helvetica")
        try check(metadata.camera.contains("X2D") && metadata.settings.contains("ISO 400") && metadata.date == "2026.10.30", "EXIF formatting")
        try check(metadata.make == "Hasselblad" && metadata.brand == .hasselblad, "EXIF manufacturer extraction")
        try check(metadata.cameraModel == "X2D 100C" && metadata.camera == "Hasselblad X2D 100C", "model display must preserve original metadata")
        for (make, model, expected) in [("Canon","Canon EOS R5","EOS R5"),("NIKON CORPORATION","NIKON Z 8","Z 8"),("OM Digital Solutions","OM-1","OM-1"),("ACME","ACME · One","One"),("Canon","Canonic 1","Canonic 1")] {
            try check(FrameMetadata(camera:model,make:make,model:model).cameraModel == expected,"model brand prefix: \(model)")
        }
        let brands: [(String, String, CameraBrand)] = [
            ("Victor Hasselblad AB", "X2D 100C", .hasselblad), ("LEICA CAMERA AG", "LEICA Q3", .leica),
            ("SONY", "ILCE-7RM5", .sony), ("Canon", "Canon EOS R5", .canon), ("NIKON CORPORATION", "NIKON Z 8", .nikon),
            ("FUJI PHOTO FILM CO., LTD.", "X-T5", .fujifilm), ("Panasonic", "DC-S5M2", .panasonic),
            ("OLYMPUS IMAGING CORP.", "E-M1MarkIII", .olympus), ("OM Digital Solutions", "OM-1", .omSystem),
            ("RICOH IMAGING COMPANY, LTD.", "RICOH GR III", .ricoh), ("RICOH IMAGING COMPANY, LTD.", "PENTAX K-1", .pentax),
            ("SIGMA", "SIGMA fp", .sigma), ("DJI", "FC3582", .dji)]
        for (make, model, expected) in brands {
            try check(CameraBrand.identify(make: "  " + make.lowercased() + "\n", model: model) == expected, "brand alias: \(make)")
        }
        try check(CameraBrand.identify(make: "Panasonic", model: "LEICA lens camera") == .panasonic, "Make must win over model")
        try check(FrameMetadata(camera: "Unknown", lens: "SIGMA 35mm", make: "ACME").brand == nil, "lens must not identify camera")
        try check(CameraBrand.identify(make: nil, model: "Canon EOS R5") == .canon, "old metadata model fallback")
        try check(CameraBrand.identify(make: "ACME", model: "SONY sensor") == nil, "unknown manufacturer should not borrow a brand")
        try check(CameraBrand.identify(make: nil, model: "Canonic") == nil, "whole token recognition")
        let oldMetadata = try JSONDecoder().decode(FrameMetadata.self, from: Data(#"{"camera":"Hasselblad X2D","lens":"","settings":"","date":""}"#.utf8))
        try check(oldMetadata.brand == .hasselblad && oldMetadata.make == nil, "old metadata snapshot compatibility")
        try check(oldMetadata.cameraModel == "X2D", "legacy metadata model display")
        var autoLogo = PhotoDecoration(); autoLogo.style = .gallery
        try check(autoLogo.logoBrand(for: metadata) == .hasselblad && autoLogo.logoBrand(for: FrameMetadata(camera: "SONY ILCE-7")) == .sony, "one preset resolves each photo separately")
        let oldDesign = try JSONDecoder().decode(PhotoDecoration.self, from: JSONEncoder().encode(autoLogo))
        try check(oldDesign.brandLogo == nil, "legacy decoration without logo key")
        try check(oldDesign.photoShadow == nil, "older decorations must default to no shadow")
        autoLogo.brandLogo = "canon"
        try check(autoLogo.logoBrand(for: metadata) == .canon, "manual logo override")
        autoLogo.brandLogo = "none"
        try check(autoLogo.logoBrand(for: metadata) == nil, "hide logo")
        autoLogo.brandLogo = "invalid"
        do { try autoLogo.validate(); throw CatalogError(message: "invalid logo accepted") } catch let error as CatalogError { try check(error.message == "相机 Logo 无效", "invalid logo validation") }
        for (_, model, brand) in brands {
            let info = FrameMetadata(camera: model, lens: "35mm F1.4", settings: metadata.settings, make: brand.rawValue)
            for dark in [false, true] {
                var design = PhotoDecoration(); design.style = .paper; design.background = dark ? "141414" : "FFFFFF"
                design.addInformationPreset("info", metadata: info, photo: base.extent.size)
                let enabled = try digest(PhotoDecorationRenderer.compose(base, decoration: design, metadata: info))
                design.stickers.removeAll { $0.logoID != nil }
                try check(enabled != digest(PhotoDecorationRenderer.compose(base, decoration: design, metadata: info)), "logo missing: \(brand)")
            }
        }
        for id in BrandStickerCatalog.ids {
            for variant in BrandStickerCatalog.variants {
                let logo = try BrandStickerCatalog.sticker(id, variant: variant)
                try StickerImport.validateSVG(logo.data!)
                let image = NSImage(data:logo.data!)!
                let context = CGContext(data:nil,width:300,height:200,bitsPerComponent:8,bytesPerRow:1200,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:false)
                let width = min(296,196*logo.aspect), height = width/logo.aspect
                image.draw(in:CGRect(x:(300-width)/2,y:(200-height)/2,width:width,height:height))
                NSGraphicsContext.restoreGraphicsState()
                let pixels = context.data!.assumingMemoryBound(to:UInt8.self)
                var transparent = 0, solid = 0
                for i in stride(from:0,to:300*200*4,by:4) {
                    if pixels[i+3] == 0 { transparent += 1 }
                    if pixels[i+3] > 250 {
                        solid += 1
                        if variant != "original" {
                            let expected = variant == "black" ? 0 : 255
                            try check((0...2).allSatisfy { abs(Int(pixels[i+$0])-expected) < 6 }, "non-monochrome logo: \(id) \(variant)")
                        }
                    }
                }
                try check(transparent > 6000 && solid > 10,"empty/opaque logo: \(id) \(variant)")
            }
        }
        var plain = PhotoDecoration(); plain.style = .paper
        let sony = FrameMetadata(camera:"SONY ILCE-7",lens:"FE 50mm",settings:"ISO 100",make:"SONY")
        try check(digest(PhotoDecorationRenderer.compose(base,decoration:plain,metadata:metadata)) == digest(PhotoDecorationRenderer.compose(base,decoration:plain,metadata:sony)), "border must not render metadata")
        plain.addInformationPreset("info",metadata:metadata,photo:base.extent.size)
        try plain.validate()
        try check(plain.stickers.count == 4 && Set(plain.stickers.compactMap(\.field)) == Set(["camera","lens","settings"]),"preset must create independent stickers")
        let boundLogo = plain.stickers.first { $0.logoID != nil }!
        try check(boundLogo.resolved(metadata).data != boundLogo.resolved(sony).data,"auto brand must follow each photo")
        try check(boundLogo.resolved(FrameMetadata()).data == nil,"unknown brand must remain blank")
        var boundText = plain.stickers.first { $0.field == "camera" }!
        try check(boundText.resolved(sony).text == "ILCE-7","model-only text metadata binding")
        let restoredText = try JSONDecoder().decode(PhotoSticker.self,from:JSONEncoder().encode(boundText))
        try check(restoredText.resolved(sony).text == "ILCE-7","model-only binding must survive saving")
        boundText.field = nil; boundText.text = "My camera"
        try check(boundText.resolved(sony).text == "My camera","custom text must override metadata")
        let textCanvas = DecorationLayout.make(photo:base.extent.size,decoration:plain).size
        for label in plain.stickers where label.kind == "text" {
            let resolved = label.resolved(metadata)
            let measured = (resolved.text as NSString).size(withAttributes:PhotoDecorationRenderer.textAttributes(resolved,canvas:textCanvas))
            let bounds = PhotoDecorationRenderer.stickerRect(resolved,canvas:textCanvas)
            try check(label.textBoxWidth == nil && label.alignment == "center" && bounds.width == measured.width,"preset must fit actual text")
        }
        var tight = PhotoSticker(); tight.text = "ISO 400"; tight.textSize = 0.05
        let tightWidth = PhotoDecorationRenderer.stickerRect(tight,canvas:textCanvas).width
        tight.text = "   ISO 400   "
        try check(PhotoDecorationRenderer.stickerRect(tight,canvas:textCanvas).width > tightWidth,"intentional spaces must retain width")
        tight.text = "ISO 400\nX"; tight.alignment = "left"; tight.textBoxWidth = 0.9
        let multiline = PhotoDecorationRenderer.stickerRect(tight,canvas:textCanvas)
        try check(multiline.width == tightWidth && multiline.height > 2*tight.textSize!*min(textCanvas.width,textCanvas.height),"multiline bounds must follow text, not legacy column")
        let paragraph = PhotoDecorationRenderer.textAttributes(tight,canvas:textCanvas)[.paragraphStyle] as! NSParagraphStyle
        try check(paragraph.alignment == .center,"all text lines must be centered")
        var legacyText = plain; tight.angle = 30; legacyText.stickers = [tight]
        let compact = legacyText.migrated(metadata:metadata,photo:base.extent.size)
        let shifted = compact.stickers[0]
        let offset = (multiline.width-0.9*textCanvas.width)/2
        try check(abs(shifted.x-(tight.x+offset*cos(.pi/6)/textCanvas.width)) < 0.00001 && abs(shifted.y-(tight.y+offset*sin(.pi/6)/textCanvas.height)) < 0.00001,"legacy rotated text anchor moved")
        try check(shifted.textBoxWidth == nil && compact.migrated(metadata:metadata,photo:base.extent.size) == compact,"tight text migration must be idempotent")
        var snap = tight; snap.x = 0.508; snap.y = 0.8
        let snapCanvas = CGSize(width:600,height:400)
        let horizontal = StickerTransform.snapped(snap,canvas:snapCanvas)
        try check(horizontal.x && !horizontal.y && horizontal.sticker.x == 0.5 && horizontal.sticker.y == snap.y && horizontal.sticker.angle == 30,"horizontal snapping must leave y and rotation unchanged")
        snap.x = 0.8; snap.y = 0.512
        let vertical = StickerTransform.snapped(snap,canvas:snapCanvas)
        try check(!vertical.x && vertical.y && vertical.sticker.x == snap.x && vertical.sticker.y == 0.5,"vertical snapping must be independent")
        snap.x = 0.508
        let both = StickerTransform.snapped(snap,canvas:snapCanvas)
        try check(both.x && both.y && both.sticker.x == 0.5 && both.sticker.y == 0.5,"both center guides")
        snap.x = 0.514
        try check(!StickerTransform.snapped(snap,canvas:snapCanvas).x && StickerTransform.snapped(snap,canvas:snapCanvas,holdingX:true).x,"snap hysteresis")
        snap.x = 0.52
        try check(!StickerTransform.snapped(snap,canvas:snapCanvas,holdingX:true).x,"drag must release beyond threshold")
        try check(!StickerTransform.snapped(snap,canvas:CGSize(width:1200,height:800)).y,"snap distance must use screen points")
        let cancelled = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try PhotoDecorationRenderer.compose(base,decoration:plain,metadata:metadata)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw CatalogError(message:"cancelled composition ran") }
        catch is CancellationError { }
        print("PASS independent center snapping, hysteresis, tight centered multiline text, whitespace, anchored migration and cancelled composition")
        let resized = StickerTransform.scaled(boundText,by:1.5)
        try check(abs(resized.textSize!-boundText.textSize!*1.5)<0.00001 && resized.x == boundText.x && resized.y == boundText.y,"scale text without moving center")
        try check(StickerTransform.angle(270) == -90,"rotation wrap")
        let handle = StickerTransform.handle(.zero,size:CGSize(width:100,height:50),angle:90,rotation:false)
        try check(abs(handle.x+25)<0.00001 && abs(handle.y-50)<0.00001,"rotated resize handle geometry")
        var rotated = boundText; rotated.angle = 37; rotated.x = 0.5; rotated.y = 0.5
        let hitCanvas = CGSize(width:600,height:400), hitRect = PhotoDecorationRenderer.stickerRect(rotated,canvas:CGSize(width:600,height:400))
        let center = CGPoint(x:hitRect.midX,y:hitRect.midY)
        for rotating in [false,true] {
            let point = StickerTransform.handle(center,size:hitRect.size,angle:rotated.angle,rotation:rotating)
            let hit = StickerTransform.hit(point,stickers:[rotated],selectedID:rotated.id,metadata:metadata,canvas:hitCanvas)
            try check(hit?.mode == (rotating ? "rotate":"scale"),"handle hit target under rotation")
        }
        var upper = rotated; upper.id = "upper"
        try check(StickerTransform.hit(center,stickers:[rotated,upper],selectedID:nil,metadata:metadata,canvas:hitCanvas)?.sticker.id == "upper","hit topmost sticker")
        upper.hidden = true
        try check(StickerTransform.hit(center,stickers:[rotated,upper],selectedID:nil,metadata:metadata,canvas:hitCanvas)?.sticker.id == rotated.id,"hidden sticker intercepted click")
        try check(StickerTransform.hit(.zero,stickers:[rotated],selectedID:rotated.id,metadata:metadata,canvas:hitCanvas) == nil,"empty canvas must deselect")
        var oldFrame = PhotoDecoration(); oldFrame.style = .galleryDark; oldFrame.showLens = false
        var oldJSON = try JSONSerialization.jsonObject(with:JSONEncoder().encode(oldFrame)) as! [String:Any]; oldJSON.removeValue(forKey:"layoutVersion")
        oldFrame = try JSONDecoder().decode(PhotoDecoration.self,from:JSONSerialization.data(withJSONObject:oldJSON))
        try check(oldFrame.layoutVersion == nil,"old layout must decode as version 1")
        let converted = oldFrame.migrated(metadata:metadata,photo:base.extent.size)
        try converted.validate()
        try check(converted.style == .paper && converted.darkBackground && converted.stickers.count == 3 && !converted.stickers.contains { $0.field == "lens" },"legacy info frame migration")
        try check(DecorationLayout.make(photo:base.extent.size,decoration:oldFrame).size == DecorationLayout.make(photo:base.extent.size,decoration:converted).size,"legacy canvas geometry")
        try check(converted.migrated(metadata:metadata,photo:base.extent.size) == converted,"migration must be idempotent")
        for size in [CGSize(width:400,height:600),CGSize(width:600,height:400),CGSize(width:4000,height:100)] {
            var narrow = PhotoDecoration(); narrow.style = .paper; narrow.footer = 0; narrow.margin = 0.01
            narrow.addInformationPreset("info",metadata:metadata,photo:size); try narrow.validate()
        }
        for photo in [CGSize(width:600,height:400),CGSize(width:400,height:600)] {
            for template in ["info","split","center"] {
                for info in [metadata, FrameMetadata(camera:"Canon EOS R5",lens:"RF 100-500mm F4.5-7.1 L IS USM",settings:metadata.settings,make:"Canon")] {
                    var design = PhotoDecoration(); design.style = .paper
                    design.addInformationPreset(template,metadata:info,photo:photo)
                    let labels = design.stickers.filter { ["camera","lens","settings"].contains($0.field ?? "") }
                    let canvas = DecorationLayout.make(photo:photo,decoration:design).size
                    try check(labels.count == 3 && labels.allSatisfy { abs($0.textSize!-labels[0].textSize!) < 0.000001 },"information font sizes must match, including fitted long models")
                    let rects = labels.map { PhotoDecorationRenderer.stickerRect($0.resolved(info),canvas:canvas) }
                    for (i,rect) in rects.enumerated() {
                        try check(rect.minX >= 0 && rect.maxX <= canvas.width,"information text outside canvas")
                        try check(rects.dropFirst(i+1).allSatisfy { !rect.intersects($0) },"compact information labels overlap")
                    }
                }
            }
            for style in [PhotoFrameStyle.none,.paper,.instant] {
                var centered = PhotoDecoration(); centered.style = style; centered.signature = "Travel"; centered.showDate = true
                var custom = PhotoSticker(); custom.id = "custom"; centered.stickers = [custom]
                centered.addInformationPreset("center",metadata:metadata,photo:photo)
                try centered.validate()
                let labels = centered.stickers.filter { $0.templateSlot != nil }
                try check(labels.count == 6 && labels.allSatisfy { abs($0.x-0.5)<0.0001 },"center preset must center every independent sticker")
                try check(Set(labels.compactMap(\.field)) == Set(["camera","lens","settings","date"]),"center preset lost live metadata")
                try check(centered.stickers.first == custom && centered.style == style,"center preset must preserve custom stickers and border")
                let canvas = DecorationLayout.make(photo:photo,decoration:centered).size
                let rects = labels.map { PhotoDecorationRenderer.stickerRect($0.resolved(metadata),canvas:canvas) }
                try check(zip(rects,rects.dropFirst()).allSatisfy { $0.maxY < $1.minY },"center preset rows overlap")
                centered.addInformationPreset("center",metadata:metadata,photo:photo)
                try check(centered.stickers.count == 7,"reapplying center preset duplicates stickers")
                _ = try bitmap(PhotoDecorationRenderer.compose(CIImage(color:.black).cropped(to:CGRect(origin:.zero,size:photo)),decoration:centered,metadata:metadata))
            }
        }
        var textAtWidthLimit = boundText; textAtWidthLimit.width = 1
        try check(abs(StickerTransform.scaled(textAtWidthLimit,by:2).textSize!-textAtWidthLimit.textSize!*2)<0.00001,"text handles must ignore the legacy image width limit")
        print("PASS centered information layouts, live fields, custom sticker preservation and independent text scaling")
        print("PASS 45 transparent logo variants, monochrome pixels, EXIF bindings, editable presets, border independence, legacy migration and handle math")
        var legacy = PhotoAdjustments(); legacy.contrast = 1.03
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        var withoutDecoration = object; withoutDecoration.removeValue(forKey: "decoration")
        try check(JSONDecoder().decode(PhotoAdjustments.self, from: JSONSerialization.data(withJSONObject: withoutDecoration)).decoration == nil, "legacy sidecars")
        let svgURL = dir.appendingPathComponent("shape.svg")
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\"><circle cx=\"50\" cy=\"50\" r=\"47\" fill=\"#FF0000\"/></svg>".utf8)
        try svg.write(to: svgURL)
        var sticker = try StickerImport.load(svgURL); sticker.x = 0.3; sticker.y = 0.4; sticker.width = 0.15
        let pngURL = dir.appendingPathComponent("sticker.png")
        try png(bitmap(CIImage(color: CIColor(red: 0,green: 1,blue: 0,alpha: 0.7)).cropped(to: CGRect(x:0,y:0,width:80,height:40))), pngURL)
        var pngSticker = try StickerImport.load(pngURL); pngSticker.x = 0.7; pngSticker.y = 0.45
        let forbidden = ["<svg><script/></svg>", "<svg><image href=\"https://example.com/a.png\"/></svg>", "<!DOCTYPE svg><svg/>", "<svg><rect fill=\"url(https://example.com/a)\"/></svg>", "<svg><g onclick=\"alert(1)\"/></svg>"]
        for text in forbidden {
            var rejected = false; do { try StickerImport.validateSVG(Data(text.utf8)) } catch { rejected = true }
            try check(rejected, "unsafe SVG accepted")
        }
        var floating = PhotoDecoration(); floating.style = .paper; floating.margin = 0.08; floating.footer = 0.08
        let flat = try PhotoDecorationRenderer.compose(base,decoration:floating,metadata:metadata)
        floating.photoShadow = true
        let raised = try PhotoDecorationRenderer.compose(base,decoration:floating,metadata:metadata)
        let shadowLayout = DecorationLayout.make(photo:base.extent.size,decoration:floating)
        let opening = CGRect(x:shadowLayout.photo.minX,y:shadowLayout.size.height-shadowLayout.photo.maxY,width:600,height:400)
        try check(flat.extent == raised.extent && digest(flat) != digest(raised),"shadow must be visible without changing canvas geometry")
        try check(digest(flat.cropped(to:opening)) == digest(raised.cropped(to:opening)),"shadow must not darken the photo itself")
        func luminance(_ image: CIImage, _ x: CGFloat, _ y: CGFloat) -> Int {
            var pixel = [UInt8](repeating:0,count:4)
            CIContext().render(image,toBitmap:&pixel,rowBytes:4,bounds:CGRect(x:x,y:y,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
            return Int(pixel[0])+Int(pixel[1])+Int(pixel[2])
        }
        try check(luminance(raised,opening.midX,opening.minY-4) < luminance(raised,opening.midX,opening.maxY+3),"floating shadow must fall below the photo")
        for rotation in 0...3 {
            let output = PhotoDecorationRenderer.rotate(try PhotoDecorationRenderer.compose(base,decoration:floating,metadata:metadata,rotation:rotation),rotation)
            let photo = PhotoDecorationRenderer.rotate(base,rotation)
            let layout = DecorationLayout.make(photo:photo.extent.size,decoration:floating)
            let region = CGRect(x:layout.photo.minX,y:layout.size.height-layout.photo.maxY,width:layout.photo.width,height:layout.photo.height)
            try check(digest(output.cropped(to:region)) == digest(photo),"rotated shadow changed photo pixels")
        }
        floating.photoShadow = nil
        try check(digest(PhotoDecorationRenderer.compose(base,decoration:floating,metadata:metadata)) == digest(flat),"disabling shadow must restore the original border")
        floating.style = .none; floating.photoShadow = true
        try check(digest(PhotoDecorationRenderer.compose(base,decoration:floating,metadata:metadata)) == digest(base),"shadow requires a border")
        print("PASS floating border shadow, direction, unchanged photo pixels, rotations and off switch")
        var d = PhotoDecoration(); d.style = .gallery; d.photoShadow = true; d.signature = "京都 / Autumn"; d.showDate = true; d.stickers = [sticker,pngSticker]
        var text = PhotoSticker(); text.text = "京都\nA quiet afternoon"; text.y = 0.72; text.font = .serif; text.angle = -12; d.stickers.append(text); d.addInformationPreset("info",metadata:metadata,photo:base.extent.size)
        for (name, _) in DecorationLibrary.builtins {
            let builtin = try StickerImport.load(PhotoDecorationRenderer.resource(name+".svg")!)
            var test = d; test.stickers = [builtin]; _ = try bitmap(PhotoDecorationRenderer.compose(base, decoration: test, metadata: metadata))
        }
        for style in PhotoFrameStyle.allCases {
            var test = d; test.style = style
            for rotation in 0...3 {
                let composed = try PhotoDecorationRenderer.compose(base, decoration: test, metadata: metadata, rotation: rotation)
                let logical = rotation%2 == 0 ? CGSize(width:600,height:400) : CGSize(width:400,height:600)
                let layout = DecorationLayout.make(photo: logical, decoration: test)
                try check(composed.extent.size == (rotation%2 == 0 ? layout.size : CGSize(width:layout.size.height,height:layout.size.width)), "layout rotation \(style) \(rotation)")
                try check(digest(composed) != digest(base), "decoration is invisible")
            }
        }
        var custom = d; custom.background = "102030"
        try check(custom.darkBackground, "custom frame contrast")
        _ = try bitmap(PhotoDecorationRenderer.compose(base, decoration: custom, metadata: metadata))
        let visible = try digest(PhotoDecorationRenderer.compose(base, decoration: d, metadata: metadata))
        var hidden = d; hidden.stickers = []
        try check(visible != digest(PhotoDecorationRenderer.compose(base, decoration: hidden, metadata: metadata)), "stickers invisible")
        var fixed = d; fixed.ratio = "4:5"
        let fixedSize = DecorationLayout.make(photo: base.extent.size, decoration: fixed).size
        try check(abs(fixedSize.width/fixedSize.height-0.8) < 0.002, "fixed ratio")
        print("PASS templates, rotations, PNG/SVG/text composition, metadata, input validation and legacy decoding")

        var doc = try PhotoEditDocument(source: EditSource.read(source)); doc.adjustments = legacy
        let first = try PhotoEditStore.commit(doc, source: source, expectedToken: nil, cache: true)!
        let cached = try cacheBytes(source)
        doc = first.document; doc.adjustments.decoration = d
        let second = try PhotoEditStore.commit(doc, source: source, expectedToken: first.token, cache: false)!
        try check(second.document.cacheRevision == second.document.revision && cacheBytes(source) == cached, "decoration-only commit lost or re-rendered photo cache")
        try FileManager.default.removeItem(at: svgURL); try FileManager.default.removeItem(at: pngURL)
        let reopened = try PhotoEditStore.read(source)!
        try check(reopened.document.frameMetadata == metadata, "EXIF snapshot not saved")
        try check(reopened.document.adjustments.decoration == d, "embedded sticker round trip")
        var hiddenOnly = PhotoAdjustments(); var hiddenD = PhotoDecoration(); var hiddenSticker = sticker; hiddenSticker.hidden = true; hiddenD.stickers = [hiddenSticker]; hiddenOnly.decoration = hiddenD
        try check(hiddenOnly.hasEffectiveChanges, "hidden stickers would be discarded on save")
        let library = DecorationLibrary(); library.stickers = [sticker, pngSticker, text]; library.presets = [DecorationPreset(name: "Travel", decoration: d)]; try library.save()
        let restoredLibrary = DecorationLibrary()
        try check(restoredLibrary.stickers == library.stickers && restoredLibrary.presets.first?.decoration == d, "library/preset persistence")
        let secondSource = dir.appendingPathComponent("second.tiff"); try original.write(to: secondSource)
        var secondDoc = try PhotoEditDocument(source: EditSource.read(secondSource)); secondDoc.adjustments.exposure = 0.5; secondDoc.adjustments.cropWidth = 0.75
        let secondBase = try PhotoEditStore.commit(secondDoc, source: secondSource, expectedToken: nil, cache: false)!
        secondDoc = secondBase.document; secondDoc.adjustments.decoration = d
        _ = try PhotoEditStore.commit(secondDoc, source: secondSource, expectedToken: secondBase.token, cache: false)
        let batchSaved = try PhotoEditStore.read(secondSource)!.document.adjustments
        try check(batchSaved.exposure == 0.5 && batchSaved.cropWidth == 0.75 && batchSaved.decoration == d, "batch application changed photo recipe")
        let preview = try PhotoEditStore.preview(source, thumbnail: false, rotation: 1)!
        let exports = dir.appendingPathComponent("exports"); try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let exported = try PhotoEditStore.export(source, to: exports.appendingPathComponent("framed.tiff"), rotation: 1, options: PhotoExportOptions(format: .tiff))
        let output = CIImage(contentsOf: exported)!
        try check(output.extent.width == preview.size.height && output.extent.height == preview.size.width, "preview/export dimensions differ")
        let expected = PhotoDecorationRenderer.rotate(CIImage(cgImage: preview.cgImage(forProposedRect:nil,context:nil,hints:nil)!), 1)
        let expectedBytes = [UInt8](try digest(expected)), actualBytes = [UInt8](try digest(output))
        try check(expectedBytes.count == actualBytes.count, "export pixel size differs")
        let error = zip(expectedBytes,actualBytes).reduce(0.0) { $0 + Double(abs(Int($1.0)-Int($1.1))) } / Double(actualBytes.count)
        try check(error < 0.7, "export differs from preview pixels: \(error)")
        try check(Data(contentsOf: source) == original, "original was modified")
        print("PASS embedded assets survive source deletion; cache retained on decoration-only commit; rotated TIFF export matches preview")

        let editor = PhotoEditorModel()
        editor.open([EditablePhoto(id:"test",name:"photo",sources:[source],rotation:0), EditablePhoto(id:"second",name:"second",sources:[secondSource],rotation:0)], selectedID:"test", batchIDs:["test"])
        try check(editor.decorationTargets.map(\.id) == ["test"], "batch selection scope leaked into navigation")
        try await wait { !editor.loading && !editor.rendering && editor.image != nil }
        try await Task.sleep(for:.milliseconds(100))
        let before = editor.parameters, renderTime = editor.previewMilliseconds
        editor.updateDecoration { $0.photoShadow = nil }
        editor.undo(); try check(editor.parameters == before,"shadow toggle must support undo")
        editor.redo(); try check(editor.decoration.photoShadow == nil,"shadow toggle must support redo")
        editor.undo()
        editor.tab = "decorate"; editor.sliderEditing(true)
        editor.updateDecoration { $0.stickers[0].x = 0.6 }
        editor.updateDecoration { $0.stickers[0].x = 0.65 }
        editor.sliderEditing(false)
        try await Task.sleep(for:.milliseconds(180))
        try check(editor.previewMilliseconds == renderTime && !editor.rendering, "sticker movement re-rendered photo")
        editor.undo(); try check(editor.parameters == before, "drag undo was not grouped")
        editor.redo(); try check(editor.decoration.stickers[0].x == 0.65, "redo failed")
        let fontSticker = editor.decoration.stickers.first { $0.kind == "text" }!
        let fontBaseline = editor.parameters
        editor.sliderEditing(true)
        editor.setStickerFontSize(fontSticker.id,pixels:30)
        editor.setStickerFontSize(fontSticker.id,pixels:36)
        editor.sliderEditing(false)
        let resizedText = editor.decoration.stickers.first { $0.id == fontSticker.id }!
        try check(abs(resizedText.textSize!*editor.stickerFontPixelScale-36)<0.0001 && resizedText.x == fontSticker.x && resizedText.text == fontSticker.text,"font size control must change glyphs without changing position or content")
        editor.undo(); try check(editor.parameters == fontBaseline,"font size drag must undo in one step")
        editor.redo()
        try await Task.sleep(for:.milliseconds(100))
        try check(editor.previewMilliseconds == renderTime && !editor.rendering,"font size change re-rendered photo")
        editor.complete()
        try await wait { !editor.isPresented }
        try check(PhotoEditStore.read(source)!.document.adjustments.decoration!.stickers.first { $0.id == fontSticker.id }!.textSize == resizedText.textSize,"font size did not persist")
        try check(PhotoEditStore.read(source)!.document.adjustments.decoration!.stickers[0].x == 0.65, "editor did not save")
        print("PASS editor drag uses cached image, grouped undo/redo, complete and reopen")

        let legacySource = dir.appendingPathComponent("legacy.tiff"); try original.write(to:legacySource)
        var legacyDoc = try PhotoEditDocument(source:EditSource.read(legacySource)); legacyDoc.adjustments.contrast = 1.02; legacyDoc.adjustments.decoration = oldFrame
        _ = try PhotoEditStore.commit(legacyDoc,source:legacySource,expectedToken:nil,cache:true)
        let legacyBytes = try Data(contentsOf:PhotoEditStore.sidecar(legacySource))
        let legacyPhoto = EditablePhoto(id:"legacy",name:"legacy",sources:[legacySource],rotation:0)
        var refreshes = 0; editor.onCommit = { _ in refreshes += 1 }
        editor.open([legacyPhoto],selectedID:"legacy")
        try await wait { !editor.loading && !editor.rendering && editor.image != nil }
        try check(editor.decoration.layoutVersion == 2 && !editor.unsaved,"migration must not mark editor dirty")
        editor.complete(); try await wait { !editor.isPresented }
        try check(refreshes == 0 && Data(contentsOf:PhotoEditStore.sidecar(legacySource)) == legacyBytes,"migration/no-op complete rewrote disk")
        editor.open([legacyPhoto],selectedID:"legacy")
        try await wait { !editor.loading && !editor.rendering && editor.image != nil }
        let baseline = editor.parameters
        editor.sliderEditing(true)
        editor.updateDecoration { $0.stickers[0] = StickerTransform.scaled($0.stickers[0],by:1.3) }
        editor.updateDecoration { $0.stickers[0].angle = 32 }
        editor.sliderEditing(false)
        editor.undo(); try check(editor.parameters == baseline,"transform undo must restore baseline")
        editor.redo(); try check(editor.decoration.stickers[0].angle == 32,"transform redo")
        editor.close(); try await wait { !editor.isPresented }
        try await Task.sleep(for:.milliseconds(300))
        try check(editor.image == nil && !editor.rendering && editor.parameters == baseline,"discarded decoration published a late preview")
        try check(refreshes == 0 && Data(contentsOf:PhotoEditStore.sidecar(legacySource)) == legacyBytes,"cancelled transformed legacy frame was saved")
        print("PASS migrated legacy edit stays clean; no-op completion and discarded handle transforms never save or refresh analysis")

        // Review artifact: actual renderer, real photo where available.
        let real = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("test_photo/B0001166.HEIC")
        var sample = (try? PhotoEditStore.decode(real, adjustments: PhotoAdjustments())) ?? base
        sample = sample.transformed(by:CGAffineTransform(scaleX: 680/max(sample.extent.width,sample.extent.height),y:680/max(sample.extent.width,sample.extent.height)))
        let board = CGContext(data:nil,width:1800,height:1500,bitsPerComponent:8,bytesPerRow:7200,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        board.setFillColor(CGColor(gray:0.16,alpha:1)); board.fill(CGRect(x:0,y:0,width:1800,height:1500))
        let styles: [PhotoFrameStyle] = [.gallery,.reportage,.cream,.galleryDark,.instant,.film]
        for (i,style) in styles.enumerated() {
            var design = PhotoDecoration(); design.style = style; design.signature = "Kyoto / 2026"; design.showDate = true
            if i < 4 { design.addInformationPreset(i == 1 ? "split":"info",metadata:metadata,photo:sample.extent.size) }
            if i == 3 { design.addInformationPreset("center",metadata:metadata,photo:sample.extent.size) }
            if i == 4 { design.addInformationPreset("caption",metadata:metadata,photo:sample.extent.size) }
            if i == 4 { var tape = try StickerImport.load(PhotoDecorationRenderer.resource("tape-sand.svg")!); tape.x=0.18; tape.y=0.08; tape.angle = -12; design.stickers.append(tape) }
            let composed = try bitmap(PhotoDecorationRenderer.compose(sample, decoration:design, metadata:metadata))
            let scale = min(550/CGFloat(composed.width),670/CGFloat(composed.height))
            board.draw(composed,in:CGRect(x:CGFloat(i%3)*600+(600-CGFloat(composed.width)*scale)/2,y:CGFloat(1-i/3)*750+40,width:CGFloat(composed.width)*scale,height:CGFloat(composed.height)*scale))
        }
        let artifact = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/decoration-preview.png")
        try png(board.makeImage()!,artifact)
        print("PASS review artifact: \(artifact.path)")
        let shadowBoard = CGContext(data:nil,width:1400,height:1000,bitsPerComponent:8,bytesPerRow:5600,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        shadowBoard.setFillColor(CGColor(gray:0.16,alpha:1)); shadowBoard.fill(CGRect(x:0,y:0,width:1400,height:1000))
        for i in 0...1 {
            var design = PhotoDecoration(); design.style = .paper; design.photoShadow = i == 1 ? true : nil
            design.addInformationPreset("info",metadata:metadata,photo:sample.extent.size)
            let result = try bitmap(PhotoDecorationRenderer.compose(sample,decoration:design,metadata:metadata))
            let scale = min(650/CGFloat(result.width),950/CGFloat(result.height))
            shadowBoard.draw(result,in:CGRect(x:CGFloat(i)*700+(700-CGFloat(result.width)*scale)/2,y:(1000-CGFloat(result.height)*scale)/2,width:CGFloat(result.width)*scale,height:CGFloat(result.height)*scale))
        }
        let shadowArtifact = artifact.deletingLastPathComponent().appendingPathComponent("photo-shadow-preview.png")
        try png(shadowBoard.makeImage()!,shadowArtifact)
        print("PASS shadow review artifact: \(shadowArtifact.path)")
        let logoBoard = CGContext(data:nil,width:1400,height:1820,bitsPerComponent:8,bytesPerRow:5600,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        logoBoard.setFillColor(CGColor(gray:0.3,alpha:1)); logoBoard.fill(CGRect(x:0,y:0,width:1400,height:1820))
        for (i, entry) in brands.enumerated() {
            let info = FrameMetadata(camera: entry.1, lens: "35mm F1.4", settings: metadata.settings, date: metadata.date, make: entry.0)
            for col in 0...1 {
                var design = PhotoDecoration(); design.style = col == 0 ? .gallery : .reportageDark; design.signature = "Kyoto / 2026"
                design.addInformationPreset(col == 0 ? "info":"split",metadata:info,photo:base.extent.size)
                let frame = try PhotoDecorationRenderer.compose(base, decoration:design, metadata:info)
                let footer = try bitmap(frame.cropped(to:CGRect(x:0,y:0,width:frame.extent.width,height:100)))
                logoBoard.draw(footer,in:CGRect(x:CGFloat(col)*700+25,y:CGFloat(12-i)*140+20,width:636,height:100))
            }
        }
        let logoArtifact = artifact.deletingLastPathComponent().appendingPathComponent("camera-logo-preview.png")
        try png(logoBoard.makeImage()!,logoArtifact)
        print("PASS brand review artifact: \(logoArtifact.path)")
        let variants = CGContext(data:nil,width:1200,height:1500,bitsPerComponent:8,bytesPerRow:4800,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        variants.setFillColor(CGColor(srgbRed:0.52,green:0.65,blue:0.7,alpha:1)); variants.fill(CGRect(x:0,y:0,width:1200,height:1500))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext:variants,flipped:false)
        for (row,id) in BrandStickerCatalog.ids.enumerated() { for (col,variant) in BrandStickerCatalog.variants.enumerated() {
            let s = try BrandStickerCatalog.sticker(id,variant:variant), width = min(260,65*s.aspect)
            NSImage(data:s.data!)!.draw(in:CGRect(x:Double(col)*400+70,y:Double(14-row)*100+15,width:width,height:width/s.aspect))
            (id as NSString).draw(at:CGPoint(x:Double(col)*400+70,y:Double(14-row)*100+2),withAttributes:[.font:NSFont.systemFont(ofSize:10),.foregroundColor:NSColor.black])
        } }
        NSGraphicsContext.restoreGraphicsState()
        try png(variants.makeImage()!,artifact.deletingLastPathComponent().appendingPathComponent("logo-variants-preview.png"))
        // Optional read-only reproduction against a large saved edit. Include the
        // first pixel access: a lazy CGImage previously hid minutes of TIFF work.
        if let path = ProcessInfo.processInfo.environment["PHOTOLAB_PREVIEW_BENCH_SOURCE"] {
            let start = Date()
            let preview = await PhotoEditStore.loadPreview(sources:[URL(fileURLWithPath:path)],thumbnail:false)
            guard let image = preview.image, let cg = image.cgImage(forProposedRect:nil,context:nil,hints:nil) else { throw CatalogError(message:preview.error ?? "missing saved preview") }
            let loaded = Date()
            let bytes = autoreleasepool { cg.dataProvider?.data.map { CFDataGetLength($0) } ?? 0 }
            try check(bytes > 0,"preview must contain pixels")
            print("BENCH saved preview \(cg.width)x\(cg.height): background \(loaded.timeIntervalSince(start))s; first pixel access \(Date().timeIntervalSince(loaded))s")
        }

    }
}
