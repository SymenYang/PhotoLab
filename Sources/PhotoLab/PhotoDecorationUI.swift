import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DecorationPreset: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var decoration: PhotoDecoration
}
@MainActor final class DecorationLibrary: ObservableObject {
    static let shared = DecorationLibrary()
    @Published var stickers: [PhotoSticker] = []
    @Published var presets: [DecorationPreset] = []
    private struct Contents: Codable { var stickers: [PhotoSticker]; var presets: [DecorationPreset] }
    private var file: URL {
        let root = ProcessInfo.processInfo.environment["PHOTOLAB_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhotoLab")
        return root.appendingPathComponent("Decorations/library.json")
    }
    init() {
        if let data = try? Data(contentsOf: file), data.count < 64_000_000, let saved = try? JSONDecoder().decode(Contents.self, from: data) {
            // Imported content is checked again when restoring the library.
            stickers = saved.stickers.filter { s in var d = PhotoDecoration(); d.stickers = [s]; return (try? d.validate()) != nil }
            presets = saved.presets.filter { (try? $0.decoration.validate()) != nil }
        }
    }
    func save() throws {
        let data = try JSONEncoder().encode(Contents(stickers: stickers, presets: presets))
        guard data.count < 64_000_000 else { throw CatalogError(message: "素材库已达 64 MB，请先移除不用的素材") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
    static let builtins: [(String, String)] = [("tape-sand", "米色胶带"), ("tape-sage", "鼠尾草胶带"), ("tape-charcoal", "深灰胶带"), ("arrow", "手绘箭头"), ("curve-arrow", "弧形箭头"), ("heart", "线描爱心"), ("star", "手绘星星"), ("label", "空白纸签"), ("ticket", "旅行票根"), ("archive", "影像档案"), ("corners", "取景角标"), ("underline", "手绘下划线")]
}

struct PhotoDecorationPanel: View {
    @ObservedObject var editor: PhotoEditorModel
    @ObservedObject private var library = DecorationLibrary.shared
    @State private var presetName = ""
    @State private var showBatch = false
    @State private var batchRunning = false
    @State private var category = "brands"
    @State private var brandVariant = "black"
    private var batchTargets: [EditablePhoto] { editor.decorationTargets.filter { $0.id != editor.current?.id } }
    private func binding<T>(_ key: WritableKeyPath<PhotoDecoration, T>) -> Binding<T> {
        Binding(get: { editor.decoration[keyPath: key] }, set: { value in editor.updateDecoration { $0[keyPath: key] = value } })
    }
    private var selected: PhotoSticker? { editor.decoration.stickers.first { $0.id == editor.selectedStickerID } }
    private func stickerBinding<T>(_ key: WritableKeyPath<PhotoSticker, T>, fallback: T) -> Binding<T> {
        Binding(get: { selected?[keyPath: key] ?? fallback }, set: { value in
            guard let id = editor.selectedStickerID else { return }
            editor.updateDecoration { d in if let i = d.stickers.firstIndex(where: { $0.id == id }) { d.stickers[i][keyPath: key] = value } }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("边框", systemImage: "photo.artframe").font(.headline)
            Picker("材质", selection: Binding(get: { editor.decoration.style }, set: { style in
                editor.updateDecoration { $0.style = style; $0.background = nil; $0.footer = style == .instant ? 0.2 : style == .paper ? 0.16 : $0.margin }
            })) {
                ForEach(PhotoFrameStyle.borders) { Text($0.title).tag($0) }
            }
            if editor.decoration.style != .none {
                ColorPicker("边框颜色", selection: Binding(get: { Color(nsColor: PhotoDecorationRenderer.color(editor.decoration.backgroundHex)) }, set: { value in
                    guard let c = NSColor(value).usingColorSpace(.sRGB) else { return }
                    editor.updateDecoration { $0.background = String(format: "%02X%02X%02X", Int((c.redComponent*255).rounded()), Int((c.greenComponent*255).rounded()), Int((c.blueComponent*255).rounded())) }
                }), supportsOpacity: false)
                Picker("画布比例", selection: binding(\.ratio)) { ForEach(["自动", "1:1", "4:5", "3:2", "2:3", "16:9"], id: \.self) { Text($0) } }
                control("边距", key: \.margin, range: 0.01...0.18)
                control("下边留白", key: \.footer, range: 0...0.35)
                Toggle("照片阴影", isOn: Binding(get: { editor.decoration.photoShadow == true }, set: { enabled in
                    editor.updateDecoration { $0.photoShadow = enabled ? true : nil }
                })).help("在照片四周添加柔和阴影，呈现悬浮在边框上的效果")
                if editor.decoration.style.textured { control("纸张纹理", key: \.texture, range: 0...1) }
            }
            DisclosureGroup("信息贴纸预设") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                    Button("左侧信息") { editor.applyInformationPreset("info") }
                    Button("两栏信息") { editor.applyInformationPreset("split") }
                    Button("居中信息") { editor.applyInformationPreset("center") }
                    Button("签名") { editor.applyInformationPreset("caption") }
                }
                Text("添加可独立编辑的文字与 Logo，不改变边框。再次选择会替换预设中的贴纸。").font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text("贴纸").font(.headline)
                Spacer()
                Button("＋文字") {
                    var s = PhotoSticker()
                    s.color = editor.decoration.darkBackground || editor.decoration.style == .none ? "F4F0E6" : "222222"
                    s.y = editor.decoration.style != .none ? 0.94 : 0.8
                    editor.addSticker(s)
                }
                Button("导入…") { importStickers() }.help("导入 PNG 或 SVG，可多选；将同时收藏到素材库")
            }
            Picker("贴纸分类", selection: $category) {
                Text("品牌 Logo").tag("brands"); Text("默认贴纸").tag("builtins"); Text("导入贴纸").tag("imports")
            }.pickerStyle(.segmented).labelsHidden()
            if category == "brands" {
                Picker("Logo 颜色", selection: $brandVariant) {
                    Text("原色").tag("original"); Text("黑色").tag("black"); Text("白色").tag("white")
                }.pickerStyle(.segmented)
                Button("＋相机品牌（自动识别）") { addLogo("auto") }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 86))], spacing: 8) {
                    ForEach(BrandStickerCatalog.ids, id: \.self) { id in
                        Button { addLogo(id) } label: {
                            VStack(spacing: 4) {
                                if let url = PhotoDecorationRenderer.resource("Brands/Variants/\(id)-\(brandVariant).svg"), let image = NSImage(contentsOf: url) {
                                    Image(nsImage: image).resizable().scaledToFit().frame(height: 32)
                                }
                                Text(BrandStickerCatalog.title(id)).font(.caption2).lineLimit(1).minimumScaleFactor(0.65)
                            }.padding(6).frame(maxWidth: .infinity).background(Color(white:0.45), in:RoundedRectangle(cornerRadius:5))
                        }.buttonStyle(.plain).accessibilityLabel("添加 " + BrandStickerCatalog.title(id))
                    }
                }
            } else if category == "builtins" {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))], spacing: 8) {
                    ForEach(DecorationLibrary.builtins, id: \.0) { item in
                        Button {
                            do { guard let url = PhotoDecorationRenderer.resource(item.0 + ".svg") else { throw CatalogError(message: "内置贴纸缺失") }; var sticker = try StickerImport.load(url); sticker.name = item.1; editor.addSticker(sticker) }
                            catch { editor.error = error.localizedDescription }
                        } label: {
                            VStack {
                                if let url = PhotoDecorationRenderer.resource(item.0 + ".svg"), let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().scaledToFit().frame(height: 30) }
                                Text(item.1).font(.caption2)
                            }.frame(maxWidth: .infinity).padding(5).background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                        }.buttonStyle(.plain)
                    }
                }
            } else {
                if library.stickers.isEmpty { Text("导入 PNG / SVG，或将文字贴纸收藏到这里。").font(.caption).foregroundStyle(.secondary) }
                ForEach(library.stickers) { item in
                    HStack {
                        Button(item.name) { var copy = item; copy.id = UUID().uuidString; copy.templateSlot = nil; editor.addSticker(copy) }.lineLimit(1)
                        Spacer()
                        Button { removeFromLibrary(item.id) } label: { Image(systemName: "minus.circle") }.help("从素材库移除")
                    }
                }
            }
            Text("拖动时靠近水平或垂直中线会自动吸附；拖右下角缩放，上方圆柄旋转。").font(.caption2).foregroundStyle(.secondary)
            if !editor.decoration.stickers.isEmpty {
                VStack(spacing: 5) {
                    ForEach(editor.decoration.stickers.reversed()) { s in
                        HStack {
                            Button { editor.selectedStickerID = s.id } label: { Label(s.kind == "text" ? String(s.resolved(editor.frameMetadata).text.prefix(20)) : s.name, systemImage: s.kind == "text" ? "textformat" : "square.on.square").lineLimit(1) }.buttonStyle(.plain)
                            Spacer()
                            Button { editor.updateDecoration { d in if let i = d.stickers.firstIndex(where: { $0.id == s.id }) { d.stickers[i].hidden.toggle() } } } label: { Image(systemName: s.hidden ? "eye.slash" : "eye") }.buttonStyle(.plain).help("显示 / 隐藏")
                        }.padding(7).background(editor.selectedStickerID == s.id ? Color.accentColor.opacity(0.17) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            if let s = selected { stickerInspector(s) }
            Divider()
            DisclosureGroup("我的预设与批量应用") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("预设名称", text: $presetName)
                        Button("收藏") { savePreset() }.disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    ForEach(library.presets) { preset in
                        HStack {
                            Button(preset.name) { editor.applyDecorationPreset(preset.decoration) }
                            Spacer()
                            Button { let old = library.presets; library.presets.removeAll { $0.id == preset.id }; do { try library.save() } catch { library.presets = old; editor.error = error.localizedDescription } } label: { Image(systemName: "minus.circle") }
                        }
                    }
                    if !batchTargets.isEmpty {
                        Button(batchRunning ? "正在保存…" : "保存装饰到其他所选的 \(batchTargets.count) 张照片…") { showBatch = true }.disabled(batchRunning || editor.saving)
                    }
                }.padding(.top, 6)
            }
            Text("模板采用原创排版；纸纹来自 ambientCG（CC0）。PNG / SVG 会随编辑文件保存，移动原素材后仍可使用。带装饰导出使用 SDR。").font(.caption2).foregroundStyle(.secondary)
        }
        .disabled(batchRunning)
        .confirmationDialog("将当前装饰保存到其他所选照片？", isPresented: $showBatch) {
            Button("保存到 \(batchTargets.count) 张照片") { applyBatch() }
        } message: { Text("替换其他所选照片的边框和贴纸，保留各自调色与裁剪，保存后更新分析结果。当前照片仍需点击完成保存；关闭当前编辑不会撤销这次批量保存。") }
    }
    private func addLogo(_ id: String) {
        do {
            var sticker = try BrandStickerCatalog.sticker(id == "auto" ? editor.frameMetadata.brand?.rawValue ?? "hasselblad" : id, variant:brandVariant)
            sticker.logoID = id; sticker.name = BrandStickerCatalog.title(id)
            editor.addSticker(sticker)
        } catch { editor.error = error.localizedDescription }
    }
    private func replaceLogo(id: String, variant: String) {
        guard let selected else { return }
        do {
            let replacement = try BrandStickerCatalog.sticker(id == "auto" ? editor.frameMetadata.brand?.rawValue ?? "hasselblad" : id,variant:variant)
            editor.updateDecoration { d in if let i = d.stickers.firstIndex(where: { $0.id == selected.id }) {
                d.stickers[i].logoID = id; d.stickers[i].logoVariant = variant; d.stickers[i].data = replacement.data; d.stickers[i].aspect = replacement.aspect
            } }
        } catch { editor.error = error.localizedDescription }
    }
    private func control(_ title: String, key: WritableKeyPath<PhotoDecoration, Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Text(title); Spacer(); Text(binding(key).wrappedValue.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit() }.font(.caption)
            Slider(value: binding(key), in: range, onEditingChanged: editor.sliderEditing).accessibilityLabel(title)
        }
    }
    private func stickerInspector(_ s: PhotoSticker) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("选中贴纸：" + s.name).font(.subheadline)
            if s.kind == "text" {
                Picker("文字来源", selection: Binding(get: { selected?.field ?? "custom" }, set: { value in
                    let current = s.resolved(editor.frameMetadata).text
                    editor.updateDecoration { d in if let i = d.stickers.firstIndex(where: { $0.id == s.id }) { d.stickers[i].field = value == "custom" ? nil : value; d.stickers[i].text = current } }
                })) {
                    Text("自定义文字").tag("custom"); Text("相机型号").tag("camera"); Text("镜头").tag("lens"); Text("拍摄参数").tag("settings"); Text("日期").tag("date")
                }
                TextEditor(text: Binding(get: { selected?.resolved(editor.frameMetadata).text ?? "" }, set: { text in
                    editor.updateDecoration { d in if let i = d.stickers.firstIndex(where: { $0.id == s.id }) { d.stickers[i].field = nil; d.stickers[i].text = String(text.prefix(500)) } }
                })).font(.body).frame(height: 64)
                Picker("字形", selection: stickerBinding(\.font, fallback: .helvetica)) { ForEach(StickerFont.allCases, id: \.self) { Text($0.title).tag($0) } }
                ColorPicker("文字颜色", selection: Binding(get: { Color(nsColor: PhotoDecorationRenderer.color(selected?.color ?? "222222")) }, set: { value in
                    guard let c = NSColor(value).usingColorSpace(.sRGB) else { return }
                    stickerBinding(\.color, fallback: "222222").wrappedValue = String(format: "%02X%02X%02X", Int((c.redComponent*255).rounded()), Int((c.greenComponent*255).rounded()), Int((c.blueComponent*255).rounded()))
                }), supportsOpacity: false)
            }
            if s.logoID != nil {
                Picker("标识", selection: Binding(get: { selected?.logoID ?? "auto" }, set: { replaceLogo(id:$0, variant:selected?.logoVariant ?? "black") })) {
                    Text("自动相机品牌").tag("auto")
                    ForEach(BrandStickerCatalog.ids, id: \.self) { Text(BrandStickerCatalog.title($0)).tag($0) }
                }
                Picker("标识颜色", selection: Binding(get: { selected?.logoVariant ?? "black" }, set: { replaceLogo(id:selected?.logoID ?? "auto",variant:$0) })) {
                    Text("原色").tag("original"); Text("黑色").tag("black"); Text("白色").tag("white")
                }.pickerStyle(.segmented)
            }
            if s.kind == "text" {
                let pixelScale = editor.stickerFontPixelScale
                let size = Binding<Double>(get: { ((selected?.textSize ?? (selected?.width ?? 0.28)*0.16)*pixelScale) }, set: { editor.setStickerFontSize(s.id,pixels:$0) })
                HStack {
                    Text("字号").font(.caption).frame(width:40,alignment:.leading)
                    Slider(value:Binding(get:{ log(max(pixelScale*0.003,size.wrappedValue)) },set:{ size.wrappedValue = exp($0) }),in:log(pixelScale*0.003)...log(pixelScale*0.5),onEditingChanged:editor.sliderEditing).accessibilityLabel("文字字号")
                    TextField("字号",value:size,format:.number.precision(.fractionLength(0...1))).frame(width:62).textFieldStyle(.roundedBorder).accessibilityLabel("文字字号数值")
                    Text("px").font(.caption).foregroundStyle(.secondary)
                }.help("按输出画布像素设置字号；文字框随内容自动调整")
            } else {
            HStack { Text("大小").font(.caption).frame(width:40,alignment:.leading)
                Slider(value: Binding(get:{ selected?.width ?? 0.28 },set:{ width in
                    editor.updateDecoration { d in if let i = d.stickers.firstIndex(where: { $0.id == s.id }) { d.stickers[i] = StickerTransform.scaled(d.stickers[i],by:width/d.stickers[i].width) } }
                }),in:0.005...1,onEditingChanged:editor.sliderEditing).accessibilityLabel("贴纸大小")
            }
            }
            stickerSlider("旋转", key: \.angle, range: -180...180)
            stickerSlider("透明度", key: \.opacity, range: 0...1)
            HStack {
                Button("水平居中") { editor.updateDecoration { d in if let i = d.stickers.firstIndex(where: { $0.id == s.id }) { d.stickers[i].x = 0.5 } } }
                Button("垂直居中") { editor.updateDecoration { d in if let i = d.stickers.firstIndex(where: { $0.id == s.id }) { d.stickers[i].y = 0.5 } } }
            }.font(.caption)
            HStack {
                Button("下移一层") { moveLayer(-1) }
                Button("上移一层") { moveLayer(1) }
            }.font(.caption)
            HStack {
                Button("复制") { var copy = s; copy.id = UUID().uuidString; copy.templateSlot = nil; copy.x = min(1,copy.x+0.03); copy.y = min(1,copy.y+0.03); editor.addSticker(copy) }
                Button("收藏贴纸") { let old = library.stickers; var copy = s; copy.id = UUID().uuidString; copy.templateSlot = nil; if copy.kind == "text" { copy.name = String(copy.text.prefix(20)) }; library.stickers.append(copy); do { try library.save() } catch { library.stickers = old; editor.error = error.localizedDescription } }
                Spacer()
                Button("删除", role: .destructive) { editor.updateDecoration { $0.stickers.removeAll { $0.id == s.id } }; editor.selectedStickerID = nil }
            }
        }.padding(10).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
    }
    private func stickerSlider(_ title: String, key: WritableKeyPath<PhotoSticker, Double>, range: ClosedRange<Double>) -> some View {
        HStack { Text(title).font(.caption).frame(width: 40, alignment: .leading); Slider(value: stickerBinding(key, fallback: range.lowerBound), in: range, onEditingChanged: editor.sliderEditing).accessibilityLabel("贴纸" + title) }
    }
    private func moveLayer(_ offset: Int) {
        guard let id = editor.selectedStickerID else { return }
        editor.updateDecoration { d in
            guard let i = d.stickers.firstIndex(where: { $0.id == id }), d.stickers.indices.contains(i+offset) else { return }
            d.stickers.swapAt(i, i+offset)
        }
    }
    private func importStickers() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .svg]; panel.allowsMultipleSelection = true
        panel.message = "选择 PNG 或静态 SVG 贴纸（单张最多 8 MB）"
        panel.begin { response in
            guard response == .OK else { return }
            Task { @MainActor in
                do {
                    let imported = try panel.urls.map { try StickerImport.load($0) }
                    var d = editor.decoration; d.stickers.append(contentsOf: imported); try d.validate()
                    let old = library.stickers; library.stickers.append(contentsOf: imported)
                    do { try library.save() } catch { library.stickers = old; throw error }
                    editor.parameters.decoration = d; editor.selectedStickerID = imported.last?.id
                } catch { editor.error = error.localizedDescription }
            }
        }
    }
    private func removeFromLibrary(_ id: String) {
        let old = library.stickers; library.stickers.removeAll { $0.id == id }
        do { try library.save() } catch { library.stickers = old; editor.error = error.localizedDescription }
    }
    private func savePreset() {
        let old = library.presets
        library.presets.append(DecorationPreset(name: String(presetName.prefix(60)), decoration: editor.decoration))
        do { try library.save(); presetName = "" } catch { library.presets = old; editor.error = error.localizedDescription }
    }
    private func applyBatch() {
        let photos = batchTargets, d = editor.decoration
        batchRunning = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                var failures: [String] = []
                var committed: Set<String> = []
                for photo in photos {
                    do {
                        let source = try PhotoEditStore.findBatchDecorationSource(photo.sources)
                        let old = try PhotoEditStore.read(source)
                        var doc = try old?.document ?? PhotoEditDocument(source: EditSource.read(source))
                        if old == nil { doc.pipelineVersion = 3; doc.adjustments.redlamp = .neutral }
                        if doc.adjustments.decoration == d { continue }
                        doc.adjustments.decoration = d
                        _ = try PhotoEditStore.commit(doc, source: source, expectedToken: old?.token, cache: false)
                        committed.insert(photo.id)
                    } catch { failures.append(photo.name + ": " + error.localizedDescription) }
                }
                return (failures, committed)
            }.value
            batchRunning = false
            if !result.1.isEmpty { editor.onBatchChange?(result.1) }
            if result.0.isEmpty { editor.status = "已保存其他所选照片的装饰；当前照片点击完成后保存" }
            else { editor.error = "部分照片未保存：\n" + result.0.joined(separator: "\n") }
        }
    }
}
extension PhotoEditStore {
    static func findBatchDecorationSource(_ sources: [URL]) throws -> URL {
        guard let source = preferredSource(sources) ?? sources.first(where: { Scanner.rawExtensions.contains($0.pathExtension.lowercased()) }) ?? sources.first else { throw CatalogError(message: "没有可编辑的原片") }
        return source
    }
}

struct PhotoDecorationCanvas: View {
    @ObservedObject var editor: PhotoEditorModel
    let image: NSImage
    @State private var gestureStart: PhotoSticker?
    @State private var gestureMode = ""
    @State private var snapX = false
    @State private var snapY = false
    private func finish() {
        if gestureStart != nil { editor.sliderEditing(false) }
        gestureStart = nil; gestureMode = ""; snapX = false; snapY = false
    }
    private func drag(_ value: DragGesture.Value, origin: CGPoint, canvas: CGSize) {
        let startPoint = CGPoint(x:value.startLocation.x-origin.x,y:value.startLocation.y-origin.y)
        let point = CGPoint(x:value.location.x-origin.x,y:value.location.y-origin.y)
        if gestureMode.isEmpty {
            let hit = StickerTransform.hit(startPoint, stickers:editor.decoration.stickers, selectedID:editor.selectedStickerID, metadata:editor.frameMetadata, canvas:canvas)
            gestureMode = hit?.mode ?? "empty"
            gestureStart = hit?.sticker
            editor.selectedStickerID = hit?.sticker.id
            if hit != nil { editor.sliderEditing(true) }
        }
        guard var changed = gestureStart else { return }
        let center = CGPoint(x:canvas.width*changed.x,y:canvas.height*changed.y)
        if gestureMode == "move" {
            changed.x = min(1,max(0,changed.x+(point.x-startPoint.x)/canvas.width))
            changed.y = min(1,max(0,changed.y+(point.y-startPoint.y)/canvas.height))
            let snapped = StickerTransform.snapped(changed,canvas:canvas,holdingX:snapX,holdingY:snapY)
            changed = snapped.sticker; snapX = snapped.x; snapY = snapped.y
        } else {
            let a = CGPoint(x:startPoint.x-center.x,y:startPoint.y-center.y)
            let b = CGPoint(x:point.x-center.x,y:point.y-center.y)
            if gestureMode == "rotate" { changed.angle = StickerTransform.angle(changed.angle+(atan2(b.y,b.x)-atan2(a.y,a.x))*180 / .pi) }
            else { changed = StickerTransform.scaled(changed,by:hypot(b.x,b.y)/max(1,hypot(a.x,a.y))) }
        }
        editor.updateDecoration { d in if let i = d.stickers.firstIndex(where: { $0.id == changed.id }) { d.stickers[i] = changed } }
    }
    var body: some View {
        GeometryReader { geometry in
            let rotation = editor.current?.rotation ?? 0
            let upright = rotation % 2 == 0 ? image.size : CGSize(width:image.size.height,height:image.size.width)
            let scale = min(max(1,geometry.size.width-72)/upright.width,max(1,geometry.size.height-110)/upright.height)
            let canvas = CGSize(width:upright.width*scale,height:upright.height*scale)
            let origin = CGPoint(x:(geometry.size.width-canvas.width)/2,y:(geometry.size.height-30-canvas.height)/2)
            ZStack(alignment:.topLeading) {
                ZStack(alignment:.topLeading) {
                    Image(nsImage:image).resizable().frame(width:image.size.width*scale,height:image.size.height*scale)
                        .rotationEffect(.degrees(Double(rotation)*90)).position(x:canvas.width/2,y:canvas.height/2)
                    if snapX {
                        Rectangle().fill(Color.accentColor).frame(width:1,height:canvas.height).position(x:canvas.width/2,y:canvas.height/2)
                    }
                    if snapY {
                        Rectangle().fill(Color.accentColor).frame(width:canvas.width,height:1).position(x:canvas.width/2,y:canvas.height/2)
                    }
                    if let s = editor.decoration.stickers.first(where: { $0.id == editor.selectedStickerID && !$0.hidden }) {
                        let r = PhotoDecorationRenderer.stickerRect(s.resolved(editor.frameMetadata),canvas:canvas)
                        Rectangle().stroke(Color.accentColor,style:StrokeStyle(lineWidth:1.5,dash:[4,3]))
                            .frame(width:max(12,r.width),height:max(12,r.height)).rotationEffect(.degrees(s.angle)).position(x:r.midX,y:r.midY)
                        ForEach([false,true],id: \.self) { rotating in
                            let point = StickerTransform.handle(CGPoint(x:r.midX,y:r.midY),size:r.size,angle:s.angle,rotation:rotating)
                            Image(systemName:rotating ? "arrow.clockwise" : "arrow.up.left.and.arrow.down.right")
                                .font(.system(size:12,weight:.bold)).foregroundStyle(.black)
                                .frame(width:26,height:26).background(Color.accentColor,in:Circle()).overlay(Circle().stroke(.black.opacity(0.5)))
                                .position(point).accessibilityLabel(rotating ? "旋转选中贴纸":"缩放选中贴纸")
                        }
                    }
                }.frame(width:canvas.width,height:canvas.height)
                    .position(x:origin.x+canvas.width/2,y:origin.y+canvas.height/2).allowsHitTesting(false)
                // A single stable hit surface keeps small or overlapping handles usable
                // while the rendered image and sticker bounds update during a gesture.
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance:0).onChanged { drag($0,origin:origin,canvas:canvas) }.onEnded { _ in finish() })
                    .accessibilityLabel("贴纸画布：拖动移动，靠近中线自动吸附，右下角缩放，上方圆柄旋转")
            }.frame(width:geometry.size.width,height:geometry.size.height)
        }.onDisappear { finish() }
    }
}
