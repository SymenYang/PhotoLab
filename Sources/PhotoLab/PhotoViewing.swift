import AppKit
import SwiftUI

struct PhotoViewingEntry: Identifiable {
    let id: String
    let name: String
    let url: URL
    let raw: Bool
    var cacheKey: String? = nil
    var rotation: Int
    var rating: Int
    var editSources: [URL] = []
    var asset: Asset? = nil
}

@MainActor final class PhotoViewingController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = PhotoViewingController()
    @Published var withinGroup = false {
        didSet { onNavigationMode?(withinGroup) }
    }
    private var navigation = PhotoNavigationSnapshot()
    private var onNavigationMode: ((Bool) -> Void)?
    var navigationLabel: String { navigation.label(for: current?.id) }
    @Published var index = 0
    @Published var entries: [PhotoViewingEntry] = []
    @Published var ratingFeedback: String?
    @Published var ratingFeedbackID = UUID()
    @Published private(set) var screenInsets = EdgeInsets()
    private(set) var screenPixelEdge = 2560
    private var onRate: ((String, Int) -> Int?)?
    private var onClose: ((String) -> Void)?
    private var onRotate: ((String, Int) -> Int?)?
    private var window: PhotoViewingWindow?
    private weak var originWindow: NSWindow?
    private var previousPresentation: NSApplication.PresentationOptions = []
    var current: PhotoViewingEntry? { entries.indices.contains(index) ? entries[index] : nil }

    func present(entries: [PhotoViewingEntry], selectedID: String, navigation: PhotoNavigationSnapshot, withinGroup: Bool, onNavigationMode: @escaping (Bool) -> Void, onClose: @escaping (String) -> Void, onRotate: @escaping (String, Int) -> Int?, onRate: @escaping (String, Int) -> Int?) {
        guard !entries.isEmpty, window == nil else { return }
        self.onClose = onClose; self.onRotate = onRotate; self.onRate = onRate
        self.entries = entries
        self.navigation = navigation.keeping(Set(entries.map(\.id)))
        self.withinGroup = withinGroup; self.onNavigationMode = onNavigationMode
        index = entries.firstIndex { $0.id == selectedID } ?? 0
        originWindow = NSApp.keyWindow
        guard let screen = originWindow?.screen ?? NSScreen.main else { return }
        updateScreenInsets(screen)
        previousPresentation = NSApp.presentationOptions
        let window = PhotoViewingWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "PhotoLab · 全屏观赏"
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.level = .floating
        window.hidesOnDeactivate = true
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        window.controller = self
        let host = NSHostingView(rootView: PhotoViewingContent(controller: self).preferredColorScheme(.dark))
        // A photo's pixel dimensions must never resize the borderless screen window.
        host.sizingOptions = []
        // Borderless windows cover the entire display, including the camera/menu
        // strip. Apply NSScreen's safe area explicitly to the photo viewport.
        host.safeAreaRegions = []
        window.contentView = host
        self.window = window
        NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
    }
    private func updateScreenInsets(_ screen: NSScreen) {
        screenPixelEdge = Int(max(screen.frame.width,screen.frame.height)*screen.backingScaleFactor)
        let safe = screen.safeAreaInsets
        screenInsets = EdgeInsets(top: safe.top, leading: safe.left, bottom: safe.bottom, trailing: safe.right)
    }
    func windowDidChangeScreen(_ notification: Notification) {
        guard let window, let screen = window.screen else { return }
        updateScreenInsets(screen)
        if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
    }
    func canMove(_ offset: Int, betweenGroups: Bool = false) -> Bool {
        navigation.target(from: current?.id, offset: offset, withinGroup: !betweenGroups && withinGroup) != nil
    }
    func move(_ offset: Int, betweenGroups: Bool = false) {
        guard let id = navigation.target(from: current?.id, offset: offset, withinGroup: !betweenGroups && withinGroup),
              let next = entries.firstIndex(where: { $0.id == id }) else { return }
        index = next
    }
    func rotate(_ turns: Int) {
        guard let entry = current, let rotation = onRotate?(entry.id, turns) else { return }
        entries[index].rotation = rotation
        entries[index].asset?.rotation = rotation
    }
    func rate(_ rating: Int) {
        guard let entry = current, let saved = onRate?(entry.id, rating) else { return }
        entries[index].rating = saved
        ratingFeedback = String(repeating: "★", count: saved)
        ratingFeedbackID = UUID()
    }
    func dismiss() { window?.close() }
    func windowWillClose(_ notification: Notification) {
        NSApp.presentationOptions = previousPresentation
        window = nil
        originWindow?.makeKeyAndOrderFront(nil)
        if let id = current?.id { onClose?(id) }
        entries = []; onNavigationMode = nil; onClose = nil; onRotate = nil; onRate = nil; ratingFeedback = nil
    }
}

final class PhotoViewingWindow: NSWindow {
    weak var controller: PhotoViewingController?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { controller?.dismiss() }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let text = event.charactersIgnoringModifiers, let rating = Int(text), (1...5).contains(rating) {
            controller?.rate(rating); return
        }
        switch event.keyCode {
        case 53: controller?.dismiss()
        case 123: controller?.move(-1)
        case 124: controller?.move(1)
        case 33: controller?.rotate(-1)
        case 30: controller?.rotate(1)
        case 24, 27, 29:
            NotificationCenter.default.post(name: .photoViewingZoom, object: event.keyCode)
        default: if event.charactersIgnoringModifiers?.lowercased() == "f" { controller?.dismiss() } else { super.keyDown(with: event) }
        }
    }
}

extension Notification.Name { static let photoViewingZoom = Notification.Name("PhotoViewingZoom") }

// Show the existing shared preview before touching originals. Upgrade only to the
// visible pixel budget, preserving the logical full-size canvas for pinch/zoom.
@MainActor final class FocusPhotoModel: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var error: String?
    @Published private(set) var hdr = false
    @Published private(set) var rotation = 0
    @Published private(set) var loading = false
    private var generation = UUID()
    private var entry: PhotoViewingEntry?
    private var original = false
    private var loadedDimension = 0
    private var upgradeTask: Task<Void,Never>?
    private var pendingDimension = 0
    typealias Cached = (Asset, Int) async -> Data?
    typealias Detail = (PhotoViewingEntry, Bool, Int) async -> (image:NSImage?, hdr:Bool, error:String?)
    private let cached: Cached
    private let detail: Detail
    init(cached: @escaping Cached = { await ImageCacheService.shared.existing(asset:$0,dimension:$1) }, detail: @escaping Detail = FocusPhotoModel.detail) {
        self.cached = cached; self.detail = detail
    }
    nonisolated static func detail(_ entry: PhotoViewingEntry, original: Bool, dimension: Int) async -> (image:NSImage?, hdr:Bool, error:String?) {
        let sources = entry.editSources.isEmpty ? [entry.url] : entry.editSources
        if !original {
            let edited = await PhotoEditStore.loadPreview(sources:sources,thumbnail:true,maxDimension:dimension,rotation:entry.rotation,logicalSize:true)
            guard !Task.isCancelled else { return (nil,false,nil) }
            if edited.source != nil { return (edited.image,false,edited.error) }
        }
        let preferred = original ? try? await PhotoEditStore.findPreferredSource(sources) : nil
        guard !Task.isCancelled else { return (nil,false,nil) }
        let source = preferred ?? entry.url
        let result = await MediaLoader.shared.photo(url:source,raw:Scanner.rawExtensions.contains(source.pathExtension.lowercased()),full:false,hdr:true,maxDimension:CGFloat(dimension),cacheKey:source == entry.url ? entry.cacheKey : nil,logicalSize:true)
        return (result.image,true,result.error)
    }
    func open(_ entry: PhotoViewingEntry, original: Bool, dimension: Int) async {
        cancel(); let token = generation
        self.entry = entry; self.original = original
        image = nil; error = nil; hdr = false; rotation = entry.rotation; loading = true; loadedDimension = 0
        if !original, let asset = entry.asset {
            for tier in [2560,1440,960,480] {
                let data = await cached(asset,tier)
                guard !Task.isCancelled, token == generation else { return }
                if let data, let preview = NSImage(data:data) { image = preview; rotation = 0; break }
            }
        }
        guard !Task.isCancelled, token == generation else { return }
        await load(dimension:max(1280,dimension),token:token)
    }
    private func load(dimension: Int, token: UUID) async {
        guard let entry else { return }
        let result = await detail(entry,original,dimension)
        guard !Task.isCancelled, token == generation else { return }
        if let image = result.image { self.image = image; hdr = result.hdr; rotation = entry.rotation; loadedDimension = dimension }
        error = result.error; loading = false
    }
    func requestResolution(_ edge: Int) {
        guard image != nil, loadedDimension > 0 else { return }
        let dimension = min(32768,((max(1280,edge)+511)/512)*512)
        guard dimension > Int(Double(loadedDimension)*1.15), dimension != pendingDimension else { return }
        upgradeTask?.cancel(); pendingDimension = dimension
        let token = generation
        upgradeTask = Task {
            do { try await Task.sleep(for:.milliseconds(180)); try Task.checkCancellation() } catch { return }
            loading = true
            await load(dimension:dimension,token:token)
            if token == generation, !Task.isCancelled { pendingDimension = 0 }
        }
    }
    func cancel() { upgradeTask?.cancel(); upgradeTask = nil; pendingDimension = 0; generation = UUID() }
}

private struct PhotoViewingContent: View {
    @ObservedObject var controller: PhotoViewingController
    @StateObject private var photo = FocusPhotoModel()
    @State private var showControls = false
    @State private var showOriginal = false
    @State private var zoomReset = 0
    @State private var zoom = 1.0
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if let image = photo.image { ZoomImage(image: image, zoom: zoom, hdr: photo.hdr, resetID: zoomReset, rotation: photo.rotation, preserveViewport:true, onPreviewSize:photo.requestResolution).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let error = photo.error { Text(error).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            VStack(spacing: 10) {
            HStack(spacing: 16) {
                Button { controller.dismiss() } label: { Label("退出观赏", systemImage: "xmark") }.help("Esc 或 F 退出")
                Text(controller.current?.name ?? "").lineLimit(1)
                Text(String(repeating: "★", count: controller.current?.rating ?? 0)).foregroundStyle(.yellow).help("1–5 设置评分")
                if let image = photo.image { Text("\(Int(image.size.width)) × \(Int(image.size.height))").font(.caption).foregroundStyle(.secondary) }
                if photo.loading { ProgressView().controlSize(.small).help("正在补充清晰度") }
                if let error = photo.error, photo.image != nil { Image(systemName:"exclamationmark.triangle").help("显示缓存预览："+error) }
                Spacer()
                Button { controller.rotate(-1) } label: { Image(systemName: "rotate.left") }.help("向左旋转 90° · [")
                Button { controller.rotate(1) } label: { Image(systemName: "rotate.right") }.help("向右旋转 90° · ]")
                Slider(value: $zoom, in: 1...8).frame(width: 120).help("缩放；也可使用触控板捏合，双指或拖动平移")
                Button("适合屏幕") { zoom = 1; zoomReset += 1 }
                Text("\(controller.index + 1) / \(controller.entries.count)").monospacedDigit()
                Button { controller.move(-1) } label: { Image(systemName: "chevron.left") }.disabled(!controller.canMove(-1))
                Button { controller.move(1) } label: { Image(systemName: "chevron.right") }.disabled(!controller.canMove(1))
            }
            HStack {
                Picker("左右切换", selection: $controller.withinGroup) {
                    Text("组间浏览").tag(false); Text("组内选片").tag(true)
                }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("照片切换范围").frame(width: 180)
                Text(controller.navigationLabel).font(.caption)
                Toggle("查看原图", isOn: $showOriginal).toggleStyle(.button)
                Button("上一组") { controller.move(-1, betweenGroups: true) }.disabled(!controller.canMove(-1, betweenGroups: true))
                Button("下一组") { controller.move(1, betweenGroups: true) }.disabled(!controller.canMove(1, betweenGroups: true))
                Spacer()
            }
            }
            .padding(16).background(.black.opacity(showControls ? 0.65 : 0))
            .opacity(showControls ? 1 : 0)
            .contentShape(Rectangle())
            .onHover { showControls = $0 }
        }
        .overlay(alignment: .bottom) {
            if let feedback = controller.ratingFeedback {
                Text(feedback).font(.title2).foregroundStyle(.yellow).padding(12)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.bottom, 24).allowsHitTesting(false)
            }
        }
        .task(id: controller.ratingFeedbackID) {
            guard controller.ratingFeedback != nil else { return }
            try? await Task.sleep(for: .seconds(1.4))
            if !Task.isCancelled { controller.ratingFeedback = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .photoViewingZoom)) { notification in
            guard let key = notification.object as? UInt16 else { return }
            if key == 29 { zoom = 1; zoomReset += 1 }
            else { zoom = min(8, max(1, zoom * (key == 24 ? 1.25 : 0.8))) }
        }
        .task(id: "\(controller.current?.id ?? "")|\(showOriginal)|\(controller.current?.rotation ?? 0)") {
            zoom = 1; zoomReset += 1
            guard let entry = controller.current else { return }
            await photo.open(entry,original:showOriginal,dimension:controller.screenPixelEdge)
        }
        .onDisappear { photo.cancel() }
        .padding(controller.screenInsets)
        .background(Color.black.ignoresSafeArea())
    }
}
