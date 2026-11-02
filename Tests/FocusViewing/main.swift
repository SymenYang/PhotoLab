import AppKit
import CoreImage
import ImageIO

actor DetailGate {
    var calls: [Int] = []
    var continuations: [CheckedContinuation<Void,Never>] = []
    func wait(_ dimension: Int) async { calls.append(dimension); await withCheckedContinuation { continuations.append($0) } }
    func release() { let pending = continuations; continuations = []; pending.forEach { $0.resume() } }
}
@main struct FocusTests {
    static func check(_ ok: @autoclosure () -> Bool, _ message: String) throws { if !ok() { throw CatalogError(message:message) } }
    @MainActor static func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<300 { if await condition() { return }; try await Task.sleep(for:.milliseconds(10)) }
        throw CatalogError(message:"focus wait timed out")
    }
    static func fixture() throws -> Data {
        try ImageCacheService.jpeg(CIImage(color:CIColor(red:0.2,green:0.4,blue:0.6)).cropped(to:CGRect(x:0,y:0,width:120,height:80)))
    }
    @MainActor static func measured(_ source: URL, full: Bool, dimension: Int, key: String? = nil) async throws -> Double {
        let start = Date()
        let result = await MediaLoader.shared.photo(url:source,raw:Scanner.rawExtensions.contains(source.pathExtension.lowercased()),full:full,hdr:true,maxDimension:CGFloat(dimension),cacheKey:key,logicalSize:true)
        guard let image = result.image, let cg = image.cgImage(forProposedRect:nil,context:nil,hints:nil) else { throw CatalogError(message:result.error ?? "decode failed") }
        // Force lazy ImageIO/Core Image pixels, including the work a first draw needs.
        let decodedBytes = autoreleasepool { cg.dataProvider?.data.map { CFDataGetLength($0) } ?? 0 }
        let seconds = Date().timeIntervalSince(start)
        try check(decodedBytes > 0,"lazy decode did not produce pixels")
        try check(full || max(cg.width,cg.height) <= dimension+1,"bounded focus decode exceeded pixel budget")
        try check(max(image.size.width,image.size.height) >= Double(max(cg.width,cg.height))-1,"lost full-size logical canvas")
        if source.pathExtension.lowercased() == "heic" { try check(cg.contentHeadroom > 1,"focus lost HDR") }
        print("BENCH \(source.lastPathComponent) \(full ? "old full" : "focus \(dimension)px") \(String(format:"%.3f",seconds))s pixels=\(cg.width)x\(cg.height) logical=\(image.size) HDR=\(cg.contentHeadroom)")
        return seconds
    }
    @MainActor static func main() async throws {
        setbuf(stdout,nil); _ = NSApplication.shared
        let bytes = try fixture(), gate = DetailGate()
        let asset = Asset(id:"fixture",rootID:"fixture",folder:"",name:"test",video:false,files:[MediaFile(relativePath:"test.jpg",size:1,modified:0)],date:0,rotation:1)
        let entry = PhotoViewingEntry(id:"fixture",name:"test",url:URL(fileURLWithPath:"/missing/test.jpg"),raw:false,rotation:1,rating:0,asset:asset)
        let model = FocusPhotoModel(cached:{ _,_ in bytes },detail:{ _,_,dimension in
            await gate.wait(dimension)
            return (NSImage(cgImage:NSImage(data:bytes)!.cgImage(forProposedRect:nil,context:nil,hints:nil)!,size:CGSize(width:6000,height:4000)),true,nil)
        })
        let opening = Task { await model.open(entry,original:false,dimension:2048) }
        try await wait { await gate.calls.count == 1 }
        try check(model.image != nil && model.rotation == 0 && !model.hdr && model.loading,"cached preview must appear before original decode and must not rotate twice")
        let initial = await gate.calls; try check(initial == [2048],"opening requested full original")
        await gate.release(); await opening.value
        try check(model.rotation == 1 && model.hdr && model.image?.size.width == 6000,"detail orientation/HDR/logical size")
        model.requestResolution(1800); try await Task.sleep(for:.milliseconds(220))
        let unchanged = await gate.calls; try check(unchanged.count == 1,"fit view repeated its decode")
        model.requestResolution(4100); model.requestResolution(4500)
        try await wait { await gate.calls.count == 2 }
        let zoomCalls = await gate.calls; try check(zoomCalls.last == 4608,"zoom should debounce and request only latest pixel tier")
        await gate.release(); try await wait { !model.loading }
        let offline = FocusPhotoModel(cached:{ _,_ in bytes },detail:{ _,_,_ in (nil,false,"offline") })
        await offline.open(entry,original:false,dimension:2048)
        try check(offline.image != nil && offline.error == "offline","offline original discarded usable preview")
        await offline.open(entry,original:true,dimension:2048)
        try check(offline.image == nil,"show original leaked edited shared cache")
        let staleGate = DetailGate()
        let stale = FocusPhotoModel(cached:{ _,_ in nil },detail:{ _,_,d in await staleGate.wait(d); return (NSImage(data:bytes),true,nil) })
        let staleTask = Task { await stale.open(entry,original:false,dimension:2048) }
        try await wait { await staleGate.calls.count == 1 }
        stale.cancel(); await staleGate.release(); await staleTask.value
        try check(stale.image == nil,"closed focus published stale decode")
        print("PASS cache-first presentation, orientation, HDR, logical size, zoom debounce, original isolation, offline fallback, stale cancellation")

        let dir = URL(fileURLWithPath:ProcessInfo.processInfo.environment["PHOTOLAB_DATA_DIR"]!)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let source = dir.appendingPathComponent("edited.jpg")
        let large = CIImage(color:CIColor(red:0.2,green:0.4,blue:0.6)).cropped(to:CGRect(x:0,y:0,width:2400,height:1600))
        try ImageCacheService.jpeg(large,dimension:2400).write(to:source)
        var doc = try PhotoEditDocument(source:EditSource.read(source)); doc.adjustments.exposure = 0.1
        var decoration = PhotoDecoration(); decoration.style = .paper; decoration.addInformationPreset("caption",metadata:FrameMetadata(),photo:CGSize(width:2400,height:1600)); doc.adjustments.decoration = decoration
        _ = try PhotoEditStore.commit(doc,source:source,expectedToken:nil,cache:true)
        let edited = await PhotoEditStore.loadPreview(sources:[source],thumbnail:true,maxDimension:960,rotation:1,logicalSize:true)
        let full = try PhotoEditStore.preview(source,thumbnail:false,rotation:1)
        try check(edited.image?.size == full?.size && edited.source == source,"edited focus logical geometry differs from full preview")
        let previewCG = edited.image!.cgImage(forProposedRect:nil,context:nil,hints:nil)!
        try check(Double(max(previewCG.width,previewCG.height)) < max(full!.size.width,full!.size.height),"edited focus accidentally decoded full output")
        let editedEntry = PhotoViewingEntry(id:"edited",name:"edited",url:source,raw:false,rotation:1,rating:0)
        let editedModel = FocusPhotoModel(); await editedModel.open(editedEntry,original:false,dimension:1280)
        try check(editedModel.image != nil && !editedModel.hdr && editedModel.error == nil,"focus skipped saved edit")
        print("PASS saved edits and borders use bounded previews with full logical geometry")
        if CommandLine.arguments.contains("--no-benchmark") { return }
        let names = ["B0001851.HEIC","DSC00001.JPG","B0001166.3FR"]
        for name in names {
            let source = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("test_photo/"+name)
            if !FileManager.default.fileExists(atPath:source.path) { continue }
            _ = try await measured(source,full:true,dimension:2880)
            _ = try await measured(source,full:false,dimension:2880,key:name)
            let warm = try await measured(source,full:false,dimension:2880,key:name)
            try check(warm < 0.5,"warm focus memory cache unexpectedly slow")
        }
    }
}
