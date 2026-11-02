import SwiftUI
import AppKit

@main struct PhotoLabApp: App {
    @StateObject private var model: LibraryModel
    @StateObject private var editor = PhotoEditorModel.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    init() {
        let custom = ProcessInfo.processInfo.environment["PHOTOLAB_DATA_DIR"]
        let directory = custom.map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhotoLab")
        do { let catalog = try Catalog(directory: directory); _model = StateObject(wrappedValue: LibraryModel(catalog: catalog)) }
        catch { fatalError("PhotoLab 无法打开数据库：\(error.localizedDescription)") }
    }
    var body: some Scene {
        WindowGroup("PhotoLab") {
            ContentView().environmentObject(model).preferredColorScheme(.dark).frame(minWidth: 1060, minHeight: 680)
                .onAppear {
                    delegate.model = model
                    if !model.loading, model.roots.isEmpty, let index = CommandLine.arguments.firstIndex(of: "--library"), CommandLine.arguments.count > index + 1 {
                        model.addRoot(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                    }
                }
        }.defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) { Button("添加目录…") { model.chooseRoot() }.keyboardShortcut("o").disabled(editor.isPresented) }
            CommandGroup(replacing: .undoRedo) {
                Button(editor.isPresented ? "撤销调整" : "撤销标记") { if editor.isPresented { editor.undo() } else { model.undo() } }
                    .keyboardShortcut("z").disabled(editor.isPresented ? editor.undoValues.isEmpty || editor.finishing : !model.undoAvailable)
                Button("重做调整") { editor.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!editor.isPresented || editor.redoValues.isEmpty || editor.finishing)
            }
            CommandMenu("选片") {
                Button("全选") {
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                        editor.selectAll(nil)
                    } else if !editor.isPresented { model.selection = Set(model.filtered.map(\.id)) }
                }.keyboardShortcut("a")
                Button("并列对比") { model.compare() }.keyboardShortcut("d").disabled(editor.isPresented)
                Button("返回网格") { model.returnToGrid() }.keyboardShortcut("g").disabled(editor.isPresented)
                Divider()
                Button("显示本地图录") { NSWorkspace.shared.open(model.catalog.directory) }
                Button("显示预览缓存") { NSWorkspace.shared.open(PreviewCache.shared.root) }
                Button("AI 模型管理…") { ModelDownloadManager.shared.show() }
                Button("缓存设置…") { model.showCacheSettings() }
                Button("重试保存未落盘的修改") { model.retrySaving() }.disabled(!model.saveFailed)
            }
        }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: LibraryModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if PhotoEditorModel.shared.isPresented {
            let alert = NSAlert(); alert.messageText = "请先完成或关闭照片编辑"; alert.informativeText = "编辑器会显示保存状态，完成后再退出应用。"; alert.runModal()
            return .terminateCancel
        }
        guard let model else { return .terminateNow }
        model.cancelScan()
        if model.saveFailed {
            let alert = NSAlert(); alert.messageText = "仍有修改未保存"; alert.informativeText = "请保留应用并检查本机磁盘空间。退出会丢失未保存的修改。"
            alert.addButton(withTitle: "取消退出"); alert.addButton(withTitle: "仍然退出")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        let noPendingWrites = model.pendingWrites == 0
        Catalog.work.async {
            Task { @MainActor in
                do {
                    try await TaskCenter.shared.flush()
                    sender.reply(toApplicationShouldTerminate: noPendingWrites || !model.saveFailed)
                } catch {
                    let alert = NSAlert(); alert.messageText = "任务进度未能保存"; alert.informativeText = error.localizedDescription; alert.runModal()
                    sender.reply(toApplicationShouldTerminate: false)
                }
            }
        }
        return .terminateLater
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let root = ProcessInfo.processInfo.environment["PHOTOLAB_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhotoLab")
        Task { await ModelService.embeddings.preloadEmbeddings(directory: root.appendingPathComponent("SemanticSearch")) }
        // Load the bundled artwork explicitly, including on first launch before
        // Launch Services has refreshed its cached Dock icon.
        if let resources = Bundle.main.resourceURL,
           let icon = NSImage(contentsOf: resources.appendingPathComponent("AppDockIcon.png")) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) {
        if ModelDownloadManager.shared.busy { ModelDownloadManager.shared.cancel() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @ObservedObject private var taskCenter = TaskCenter.shared
    @State private var showTasks = false
    @StateObject private var editor = PhotoEditorModel.shared
    @StateObject private var ruleEmbeddings = RuleEmbeddingSearchModel()
    @StateObject private var semantic = SemanticSearchModel()
    @StateObject private var siglipIndex = SemanticSearchModel(backend: "siglip")
    @StateObject private var qwenIndex = SemanticSearchModel(backend: "qwen")
    @StateObject private var artIndex = SemanticSearchModel(backend: "art")
    @StateObject private var qualityIndex = SemanticSearchModel(backend: "quality")
    @AppStorage("expandDirectories") private var expandDirectories = true
    @State private var sidebarContentHeights: [String: CGFloat] = [:]
    @AppStorage("expandSavedFilters") private var expandSavedFilters = true
    @AppStorage("expandTags") private var expandTags = true
    @AppStorage("expandAnalysis") private var expandAnalysis = true
    @State private var photoRatios: [String: Double] = [:]
    @EnvironmentObject var model: LibraryModel
    @AppStorage("showDirectorySidebar") private var showDirectorySidebar = true
    @AppStorage("showInspectorSidebar") private var showInspectorSidebar = true
    @AppStorage("showFilterBar") private var showFilterBar = true
    @State private var showExport = false
    @State private var saveFilter = false
    @State private var filterName = ""
    @AppStorage("gridTileSize") private var tileSize = 225.0
    @State private var zoomReset = 0
    @State private var zoom = 1.0
    @State private var monitor: Any?
    var body: some View {
        HSplitView {
            if showDirectorySidebar {
                sidebar.frame(minWidth: 195, idealWidth: 215, maxWidth: 280).disabled(editor.isPresented)
            }
            VStack(spacing: 0) {
                header.disabled(editor.isPresented)
                if showFilterBar && !editor.isPresented { filters }
                Divider()
                ZStack {
                    // Keep the saved browsing image alive while editing a draft.
                    // Discard can reveal it immediately; an explicit save still
                    // reloads it through the library's edit revision.
                    Group {
                        if model.loading { ProgressView("正在载入本地图录…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                        else if model.roots.isEmpty { welcome }
                        else if model.filtered.isEmpty && model.mode == "grid" { ContentUnavailableView("没有匹配的素材", systemImage: model.scanning ? "arrow.trianglehead.2.clockwise" : "line.3.horizontal.decrease", description: Text(semantic.busy ? "正在本地检索…" : model.scanning ? "正在扫描目录，完成后显示素材。" : "调整搜索文字或筛选条件。" )).frame(maxWidth: .infinity, maxHeight: .infinity) }
                        else {
                            ZStack {
                                grid.opacity(model.mode == "grid" ? 1 : 0)
                                    .allowsHitTesting(model.mode == "grid").accessibilityHidden(model.mode != "grid")
                                if model.mode != "grid" { viewer }
                            }
                        }
                    }
                    .opacity(editor.isPresented ? 0 : 1)
                    .allowsHitTesting(!editor.isPresented)
                    .accessibilityHidden(editor.isPresented)
                    if editor.isPresented { PhotoEditorView(editor: editor) }
                }
                Divider()
                if editor.isPresented { HStack { taskButton; Spacer() }.padding(8) } else { footer }
            }.frame(minWidth: 570, maxHeight: .infinity)
            if editor.isPresented {
                PhotoEditorView(editor: editor, inspectorOnly: true).frame(minWidth: 300, idealWidth: 320, maxWidth: 400)
            } else if showInspectorSidebar {
                Inspector().frame(minWidth: 230, idealWidth: 255, maxWidth: 310)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(model.rootWritePending)
        .background(Color(red: 0.075, green: 0.085, blue: 0.10))
        .tint(Color(red: 0.71, green: 0.86, blue: 0.54))
        .alert("PhotoLab", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("好") { model.error = nil } } message: { Text(model.error ?? "") }
        .environmentObject(semantic)
        .onChange(of: semantic.reference?.id) { _, id in
            if id != nil { model.mode = "grid" }
        }
        .task(id: ruleEmbeddingRequestID) {
            await ruleEmbeddings.refresh(model, indexIdentity: "\(siglipIndex.revision)|\(qwenIndex.revision)")
        }
        .task(id: semanticRequestID) {
            semantic.resetResults(model)
            guard semantic.enabled, !semantic.indexing, semantic.reference != nil || !semantic.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            model.semanticIDs = []
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            semantic.search(model, similar: semantic.reference != nil)
        }
        .task {
            await semantic.refresh(model)
            await qwenIndex.refresh(model)
            await artIndex.refresh(model)
            await qualityIndex.refresh(model)
        }
        .task(id: "\(model.similarityThreshold)|\(model.loading)|\(model.rootsResolved)|\(model.checkingAnalysisEdits)") {
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            await siglipIndex.refreshSimilarityGroups(model)
        }
        .task(id: "\(model.contentRevision)|\(model.loading)|\(model.rootsResolved)|\(model.scanning)|\(siglipIndex.busy)|\(siglipIndex.autoPaused)|\(model.checkingAnalysisEdits)|\(taskCenter.loaded)") {
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            await siglipIndex.automaticallyIndex(model)
        }
        .task(id: "\(model.contentRevision)|\(model.loading)|\(model.checkingAnalysisEdits)|\(qwenIndex.busy)|\(artIndex.busy)|\(qualityIndex.busy)|\(model.scanning)|\(model.rootsResolved)|\(taskCenter.loaded)") {
            do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
            await qwenIndex.automaticallyRefreshEdits(model)
            await artIndex.automaticallyRefreshEdits(model)
            await qualityIndex.automaticallyRefreshEdits(model)
        }
        .onReceive(NotificationCenter.default.publisher(for: .photoLabEdit)) { note in
            if let id = note.object as? String, let asset = model.assets.first(where: { $0.id == id }) { openEditor(asset) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.editRevision += 1; model.scheduleAnalysisEdits() }
        .sheet(isPresented: $showTasks) { TaskCenterPanel() }
        .sheet(isPresented: $showExport) { ExportSheet().environmentObject(model) }
        .alert("保存筛选器", isPresented: $saveFilter) { TextField("名称", text: $filterName); Button("保存") { model.saveFilter(name: filterName); filterName = "" }; Button("取消", role: .cancel) {} }
        .onAppear {
            installKeys(); MediaLoader.shared.trimCache(); model.registerTaskRecovery()
            taskCenter.register("index") { recipe in
                guard !model.loading, model.rootsResolved else { model.error = "图库尚未就绪，请稍后继续任务"; return false }
                let runner = recipe.backend == "qwen" ? qwenIndex : recipe.backend == "art" ? artIndex : recipe.backend == "quality" ? qualityIndex : siglipIndex
                let ids = Set(recipe.ids)
                runner.index(model, photos: model.assets.filter { ids.contains($0.id) }, scopeName: "恢复未完成任务")
                return true
            }
        }
        .onChange(of: model.mode) { _, value in
            if value == "single" && model.focusID == nil { model.enterSingle() }
            if value == "grid", let asset = model.focused { model.selection = [asset.id]; model.rebuild() }
        }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Image(systemName: "camera.aperture").font(.system(size: 25)); Text("PhotoLab").font(.system(size: 23, weight: .semibold, design: .rounded)); Spacer() }.padding(20)
            Text("你的照片与视频图录").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 22)
            navRow("所有素材", icon: "square.grid.2x2", active: model.filter.rootID == nil, count: model.assets.count) { model.filter.rootID = nil; model.filter.folder = nil }
                .padding(.horizontal, 15).padding(.bottom, 12)
            GeometryReader { geometry in
                let heights = sidebarSectionHeights(available: geometry.size.height)
                VStack(alignment: .leading, spacing: 10) {
                    sidebarSection("目录", key: "directories", expanded: $expandDirectories, height: heights["directories", default: 0]) {
                        ForEach(model.roots) { root in
                            DisclosureGroup {
                                navRow("整个目录", icon: "folder", active: model.filter.rootID == root.id && model.filter.folder == nil) { model.filter.rootID = root.id; model.filter.folder = nil }
                                ForEach(model.folders(for: root), id: \.self) { folder in
                                    navRow(folder, icon: "folder", active: model.filter.rootID == root.id && model.filter.folder == folder) { model.filter.rootID = root.id; model.filter.folder = folder }.help(folder)
                                        .contextMenu {
                                            cacheBuildButtons(root: root, folder: folder)
                                            Divider()
                                            Button("从图库移除…") { model.removeFolder(root, folder: folder) }.disabled(model.scanning || model.saveFailed)
                                        }
                                }
                            } label: {
                                Label(root.name + (model.rootState[root.id].map { " · " + $0 } ?? ""), systemImage: "externaldrive").font(.system(size: 12, weight: .medium)).lineLimit(1)
                            }
                            .contextMenu {
                                cacheBuildButtons(root: root)
                                Divider()
                                Button("继续扫描 / 刷新索引") { model.scan(root) }.disabled(model.scanning)
                                Button("从头重新扫描") { model.restartScan(root) }.disabled(model.scanning)
                                Button("重新关联位置…") { model.relink(root) }.disabled(model.scanning)
                                Button("从图库移除…") { model.removeRoot(root) }.disabled(model.scanning || model.saveFailed)
                                Divider()
                                Button("在 Finder 中显示") { NSWorkspace.shared.open(URL(fileURLWithPath: root.path)) }
                            }.padding(.vertical, 5)
                        }
                        Button { model.chooseRoot() } label: { Label("添加目录", systemImage: "plus") }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.vertical, 8).disabled(model.scanning)
                    }
                    sidebarSection("已保存的筛选器", key: "saved", expanded: $expandSavedFilters, height: heights["saved", default: 0]) {
                        if model.savedFilters.isEmpty { Text("把常用筛选保存到这里").font(.caption).foregroundStyle(.tertiary).padding(.vertical, 4) }
                        ForEach(model.savedFilters.filter { saved in saved.state.rootID == nil || model.roots.contains { $0.id == saved.state.rootID } }) { saved in
                            navRow(saved.name, icon: "line.3.horizontal.decrease.circle", active: model.filter == saved.state) { model.filter = saved.state }
                                .contextMenu { Button("删除筛选器") { model.deleteFilter(saved.id) } }
                        }
                    }
                    sidebarSection("标签", key: "tags", expanded: $expandTags, height: heights["tags", default: 0]) {
                        if model.allTags.isEmpty { Text("暂无标签").font(.caption).foregroundStyle(.tertiary).padding(.vertical, 4) }
                        ForEach(model.allTags, id: \.self) { tag in navRow(tag, icon: "tag", active: model.filter.hasTag(tag)) { model.filter.toggleTag(tag) } }
                    }
                    sidebarSection("AI 分析", key: "analysis", expanded: $expandAnalysis, height: heights["analysis", default: 0]) {
                        AnalysisPanel(siglip: siglipIndex, qwen: qwenIndex, art: artIndex, quality: qualityIndex)
                    }
                    Spacer(minLength: 0)
                }
            }.padding(.horizontal, 15)
            VStack(alignment: .leading, spacing: 5) {
                Label("本机图录", systemImage: "internaldrive").font(.caption)
                Text("\(model.assets.count) 个项目 · \(ByteCountFormatter.string(fromByteCount: model.totalBytes, countStyle: .file)) 原片").font(.caption2).foregroundStyle(.secondary)
                Text("原文件只读 · 无视频转码").font(.caption2).foregroundStyle(.tertiary)
            }.padding(18)
        }.background(Color.white.opacity(0.025))
    }
    // The four headings stay visible. Only their content areas share the remaining height.
    private func sidebarSectionHeights(available: CGFloat) -> [String: CGFloat] {
        let sections: [(String, Bool, CGFloat)] = [("directories", expandDirectories, 260), ("saved", expandSavedFilters, 30), ("tags", expandTags, 30), ("analysis", expandAnalysis, 170)]
        var result = Dictionary(uniqueKeysWithValues: sections.map { ($0.0, $0.1 ? sidebarContentHeights[$0.0, default: $0.2] : 0) })
        var budget = max(0, available - 4 * 24 - 4 * 10)
        var pending = sections.filter { $0.1 }.map { $0.0 }
        // Short sections keep their natural height; long sections share unused space.
        while !pending.isEmpty {
            let share = budget / CGFloat(pending.count)
            let short = pending.filter { result[$0, default: 0] <= share }
            if short.isEmpty { for key in pending { result[key] = share }; break }
            for key in short { budget -= result[key, default: 0] }
            pending.removeAll { short.contains($0) }
        }
        return result
    }
    private func sidebarSection<Content: View>(_ title: String, key: String, expanded: Binding<Bool>, height: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.wrappedValue.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 10)
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                }.contentShape(Rectangle()).frame(height: 24)
            }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(expanded.wrappedValue ? "已展开" : "已收起")
            if expanded.wrappedValue {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 7) { content() }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 17).padding(.trailing, 3).padding(.vertical, 5)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { value in
                            if abs(sidebarContentHeights[key, default: 0] - value) > 0.5 { sidebarContentHeights[key] = value }
                        }
                }.frame(height: height).scrollBounceBehavior(.basedOnSize).accessibilityLabel(title + "内容")
            }
        }.accessibilityElement(children: .contain)
    }
    private func navRow(_ title: String, icon: String, active: Bool, count: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Image(systemName: icon).frame(width: 17); Text(title).lineLimit(1).truncationMode(.middle); Spacer(minLength: 0); if let count { Text("\(count)").foregroundStyle(.secondary) } }
                .font(.system(size: 12)).padding(.horizontal, 9).padding(.vertical, 7).background(active ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }
    private var header: some View {
        HStack(spacing: 14) {
            Button { showDirectorySidebar.toggle() } label: {
                Image(systemName: "sidebar.left")
            }
            .help(showDirectorySidebar ? "收起目录栏 · ⇧⌘L" : "展开目录栏 · ⇧⌘L")
            .accessibilityLabel(showDirectorySidebar ? "收起目录栏" : "展开目录栏")
            .keyboardShortcut("l", modifiers: [.command, .shift])
            VStack(alignment: .leading, spacing: 4) {
                Text(model.filter.folder?.isEmpty == false ? (model.filter.folder! as NSString).lastPathComponent : model.roots.first(where: { $0.id == model.filter.rootID })?.name ?? "所有素材").font(.title2.weight(.semibold))
                Text("\(model.filtered.count) 个项目  /  已选 \(model.selection.count)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            aiSearch
            Button { showFilterBar.toggle() } label: {
                Image(systemName: showFilterBar ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .overlay(alignment: .topTrailing) {
                        if !showFilterBar && (model.semanticIDs != nil || model.filter.hasRules) {
                            Circle().fill(Color.accentColor).frame(width: 5, height: 5).offset(x: 3, y: -3)
                        }
                    }
            }
            .help(showFilterBar ? "收起搜索与筛选 · ⇧⌘S" : "展开搜索与筛选（筛选条件仍生效）· ⇧⌘S")
            .accessibilityLabel(showFilterBar ? "收起搜索与筛选" : "展开搜索与筛选")
            .keyboardShortcut("s", modifiers: [.command, .shift])
            Button { model.compare() } label: { Label("对比", systemImage: "rectangle.split.2x1") }.disabled(model.selectedAssets.count < 2)
            Button { showExport = true } label: { Label("导出", systemImage: "square.and.arrow.up") }.disabled(model.filtered.isEmpty || model.exporting || model.querying)
            Button { showInspectorSidebar.toggle() } label: {
                Image(systemName: "sidebar.right")
            }
            .help(showInspectorSidebar ? "收起信息栏 · ⇧⌘R" : "展开信息栏 · ⇧⌘R")
            .accessibilityLabel(showInspectorSidebar ? "收起信息栏" : "展开信息栏")
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }.padding(20)
    }
    private var aiSearch: some View {
        HStack(spacing: 6) {
            TextField(semantic.reference.map { "相似照片：\($0.name)" } ?? "AI 搜索：描述画面", text: Binding(
                get: { semantic.text },
                set: { semantic.reference = nil; semantic.enabled = true; semantic.text = $0; model.mode = "grid" }
            )).textFieldStyle(.roundedBorder)
                .onSubmit { semantic.search(model, similar: semantic.reference != nil) }
                .accessibilityLabel("AI 搜索")
                .help(semantic.error ?? semantic.message)
            if semantic.busy { ProgressView().controlSize(.mini) }
            if !semantic.text.isEmpty || semantic.reference != nil {
                Button { semantic.text = ""; semantic.reference = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).help("清除 AI 搜索")
            }
            if let error = semantic.error { Image(systemName: "exclamationmark.circle").foregroundStyle(.red).help(error) }
        }.frame(minWidth: 160, idealWidth: 280, maxWidth: 400)
    }
    private var semanticRequestID: String {
        return "\(model.contentRevision)|\(semantic.backend)|\(semantic.enabled)|\(semantic.text)|\(semantic.reference?.id ?? "")|\(semantic.indexing)|\(model.filter.scopeIdentity)"
    }
    private var ruleEmbeddingRequestID: String {
        let queries = (try? JSONEncoder().encode(model.filter.embeddingQueries)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return "\(model.contentRevision)|\(model.loading)|\(model.filter.scopeIdentity)|\(queries)|\(siglipIndex.revision)|\(qwenIndex.revision)|\(ruleEmbeddings.retryRevision)"
    }
    private var filters: some View {
        RuleFilterPanel(embeddings: ruleEmbeddings) { saveFilter = true }
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.aperture").font(.system(size: 70, weight: .ultraLight)).foregroundStyle(.secondary)
            Text("让值得留下的画面，留下来。").font(.title2)
            Text("添加本地或网络共享目录。照片与 RAW 自动配对，\n视频直接预览，评分和标签安全保存在本机。").multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("添加素材目录…") { model.chooseRoot() }.buttonStyle(.borderedProminent).controlSize(.large)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize), spacing: 14)], spacing: 18, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.gridSections, id: \.0) { section in
                        Section {
                                ForEach(section.1) { asset in
                                    AssetTile(asset: asset, selected: model.selection.contains(asset.id), focused: model.focusID == asset.id)
                                        .id(asset.id)
                                        .onAppear { if asset.id == model.lastGridID { model.loadNextPage() } }
                                        .onTapGesture(count: 2) { model.select(asset); model.enterSingle() }
                                        .onTapGesture { model.select(asset, modifiers: NSEvent.modifierFlags) }
                                }
                        } header: {
                            if !section.0.isEmpty {
                                HStack { Text(section.0).font(.headline); Text("\(section.1.count) 个项目").foregroundStyle(.secondary); Spacer() }
                                    .padding(.vertical, 10).background(Color(red: 0.075, green: 0.085, blue: 0.10))
                            }
                        }
                    }
                }.padding(20)
                if model.gridLimit < model.visibleAssets.count {
                    ProgressView("继续加载…").padding()
                }
            }
            .onGeometryChange(for: Int.self) { geometry in
                max(1, Int((geometry.size.width - 40 + 14) / (tileSize + 14)))
            } action: { columns in model.gridColumns = columns }
            .onAppear { if let id = model.focusID { proxy.scrollTo(id) } }
            .onChange(of: model.focusID) { _, id in
                if model.mode == "grid", let id { proxy.scrollTo(id) }
            }
            .onChange(of: model.mode) { _, mode in
                if mode == "grid", let id = model.focusID { proxy.scrollTo(id) }
            }
            .onChange(of: model.groupByCaptureDate) { _, _ in
                if let id = model.focusID { proxy.scrollTo(id) }
            }
            .onChange(of: model.indexingDates) { _, loading in
                if !loading, model.mode == "grid", let id = model.focusID { proxy.scrollTo(id) }
            }
        }
    }
    private var viewer: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.returnToGrid() } label: { Label("网格", systemImage: "chevron.left") }
                if model.mode == "single" {
                    Picker("左右切换", selection: $model.withinPhotoGroup) {
                        Text("组间浏览").tag(false)
                        Text("组内选片").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("照片切换范围").frame(width: 180)
                    Text(model.photoNavigationLabel).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("预览缩放").font(.caption).foregroundStyle(.secondary)
                Slider(value: $zoom, in: 1...4).frame(width: 110)
                Button("适合窗口") { zoom = 1; zoomReset += 1 }
            }.padding(10)
            if model.mode == "compare" {
                let entries = model.compareIDs.compactMap { id in model.assets.first { $0.id == id } }
                GeometryReader { geometry in
                    let rows = comparisonRows(entries, size: geometry.size)
                    let height = max(1, (geometry.size.height - CGFloat(rows - 1) * 6) / CGFloat(rows))
                    VStack(spacing: 6) {
                        ForEach(0..<rows, id: \.self) { row in
                            let start = row * entries.count / rows
                            let end = (row + 1) * entries.count / rows
                            let count = max(1, end - start)
                            let width = max(1, (geometry.size.width - CGFloat(count - 1) * 6) / CGFloat(count))
                            HStack(spacing: 6) {
                                ForEach(Array(entries[start..<end])) { asset in
                                    panel(asset, compare: true).frame(width: width, height: height).clipped()
                                }
                            }
                        }
                    }
                    .onPreferenceChange(PhotoAspectRatios.self) { photoRatios.merge($0, uniquingKeysWith: { _, new in new }) }
                }.padding(6)
            } else if let asset = model.focused ?? model.filtered.first { panel(asset, compare: false).frame(maxHeight: .infinity) }
            HStack {
                if model.mode == "single" {
                    Button("上一组") { model.movePhoto(-1, betweenGroups: true) }.disabled(!model.canMovePhoto(-1, betweenGroups: true))
                }
                Button { model.move(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(model.mode == "single" && !model.canMovePhoto(-1))
                Text("← → 切换 · 0–5 评分 · P 保留 · X 淘汰 · U 清除状态").font(.caption).foregroundStyle(.secondary)
                Button { model.move(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(model.mode == "single" && !model.canMovePhoto(1))
                if model.mode == "single" {
                    Button("下一组") { model.movePhoto(1, betweenGroups: true) }.disabled(!model.canMovePhoto(1, betweenGroups: true))
                }
            }.padding(10)
        }
    }
    private func comparisonRows(_ entries: [Asset], size: CGSize) -> Int {
        guard !entries.isEmpty else { return 1 }
        // Choose the arrangement that displays the most image area without cropping.
        return (1...entries.count).max { area($0) < area($1) } ?? 1
        func area(_ rows: Int) -> Double {
            let height = max(1, (size.height - Double(rows - 1) * 6) / Double(rows) - 80)
            return (0..<rows).reduce(0) { total, row in
                let start = row * entries.count / rows
                let end = (row + 1) * entries.count / rows
                let width = max(1, (size.width - Double(end - start - 1) * 6) / Double(end - start))
                return total + entries[start..<end].reduce(0) { sum, asset in
                    let ratio = photoRatios[asset.id] ?? (asset.video ? 16.0 / 9.0 : 0.75)
                    let imageWidth = min(width, height * ratio)
                    return sum + imageWidth * imageWidth / ratio
                }
            }
        }
    }
    private func panel(_ asset: Asset, compare: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(asset.name).font(.caption.weight(.medium)).lineLimit(1)
                if asset.rating > 0 { Text(String(repeating: "★", count: asset.rating)).foregroundStyle(Color.accentColor) }
                Spacer()
                if !asset.video {
                    Button { openEditor(asset) } label: { Label("编辑", systemImage: "slider.horizontal.3") }.help("编辑照片 · E")
                    Button { model.rotate(asset.id, by: -1) } label: { Image(systemName: "rotate.left") }.buttonStyle(.plain).help("向左旋转 90°，自动保存")
                    Button { model.rotate(asset.id, by: 1) } label: { Image(systemName: "rotate.right") }.buttonStyle(.plain).help("向右旋转 90°，自动保存")
                }
                if compare { Button { model.pinnedID = model.pinnedID == asset.id ? nil : asset.id } label: { Image(systemName: model.pinnedID == asset.id ? "pin.fill" : "pin") }.buttonStyle(.plain).help("固定为参考；方向键替换另一面板") }
            }.padding(10)
            if let url = model.url(for: asset) {
                if asset.video { VideoView(asset: asset, url: url, active: !compare || model.focusID == asset.id) }
                else { PhotoView(asset: asset, url: url, rawURL: asset.files.first(where: \.isRAW).flatMap { model.url(for: asset, file: $0) }, compact: compare, resetID: zoomReset, zoom: $zoom) }
            }
        }.background(Color.black.opacity(0.2)).overlay(RoundedRectangle(cornerRadius: 4).stroke(model.focusID == asset.id ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1))
            .simultaneousGesture(TapGesture().onEnded { if compare { model.select(asset) } })
    }
    @ViewBuilder private func cacheBuildButtons(root: LibraryRoot, folder: String? = nil) -> some View {
        Button("构建缩略图缓存（含子目录）") { model.buildCache(root: root, folder: folder, kind: .thumbnails) }
            .disabled(model.buildingCache || model.loading)
        Button("缓存原片（含子目录）") { model.buildCache(root: root, folder: folder, kind: .originals) }
            .disabled(model.buildingCache || model.loading)
    }
    private var taskButton: some View {
            Button { showTasks = true } label: { Label("任务中心 · \(taskCenter.activeCount)", systemImage: "list.bullet.rectangle") }.font(.caption)
                .help(taskCenter.activeRecords.first.map { $0.title + " · " + $0.detail } ?? "没有未完成任务")
    }
    private var footer: some View {
        HStack {
            taskButton
            if model.scanning || model.exporting { ProgressView().controlSize(.mini) }
            if model.scanning { Button("停止扫描") { model.cancelScan() }.font(.caption) }
            if model.exporting { Button("停止导出") { model.cancelExport() }.font(.caption) }
            Spacer(minLength: 5)
            if model.indexingDates { ProgressView().controlSize(.mini).help("正在后台读取拍摄日期，分批更新分组；关闭分组可停止") }
            Toggle("聚合相似照片", isOn: $model.aggregateSimilar).toggleStyle(.checkbox).font(.caption)
                .help("自动折叠高度相似的照片；AI 搜索期间显示全部结果")
            TextField("阈值", value: $model.similarityThreshold, format: .number.precision(.fractionLength(0...4)))
                .textFieldStyle(.roundedBorder).frame(width: 64)
                .accessibilityLabel("相似照片聚合阈值").help("相似度阈值 −1 到 1，越高越严格")
            Toggle("按拍摄日期分组", isOn: $model.groupByCaptureDate).toggleStyle(.checkbox).font(.caption)
            if model.semanticIDs != nil { Text("按 AI 相关性排序").font(.caption).foregroundStyle(.secondary) }
            else { Picker("排序", selection: $model.filter.sort) { Text("名称").tag("name"); Text("文件修改时间").tag("date"); Text("手动星级").tag("rating"); Text("艺术分 ↓").tag("artHigh"); Text("艺术分 ↑").tag("artLow"); Text("质量分 ↓").tag("qualityHigh"); Text("质量分 ↑").tag("qualityLow") }.labelsHidden().frame(width: 115) }
            if model.mode == "grid" { Slider(value: $tileSize, in: 120...600).frame(width: 110).accessibilityLabel("缩略图大小").help("缩略图大小：120–600，宽度和高度同步缩放") }
        }.padding(10)
    }
    private func installKeys() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !editor.isPresented, NSApp.keyWindow != nil, !(NSApp.keyWindow is PhotoViewingWindow), NSApp.modalWindow == nil, NSApp.keyWindow?.attachedSheet == nil,
                  !(NSApp.keyWindow?.firstResponder is NSTextView) else { return event }
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) { return event }
            if model.mode == "grid" && (event.keyCode == 125 || event.keyCode == 126) {
                model.moveGridRow(event.keyCode == 125 ? 1 : -1)
                return nil
            }
            if event.keyCode == 123 || event.keyCode == 124 {
                let delta = event.keyCode == 123 ? -1 : 1
                if event.modifierFlags.contains(.option) && model.mode != "grid" { NotificationCenter.default.post(name: .photoLabPlayback, object: delta) }
                else { model.move(delta) }
                return nil
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "e": if let asset = model.focused ?? model.filtered.first { openEditor(asset) }; return nil
            case "f": presentPhoto(); return nil
            case "[", "]": if let asset = model.focused { model.rotate(asset.id, by: event.charactersIgnoringModifiers == "[" ? -1 : 1) }; return nil
            case "0", "1", "2", "3", "4", "5": model.mark(rating: Int(event.charactersIgnoringModifiers!)!); return nil
            case "p": model.mark(flag: 1); return nil
            case "x": model.mark(flag: -1); return nil
            case "u": model.mark(flag: 0); return nil
            case " ":
                if model.mode == "grid" { model.enterSingle() }
                else if model.focused?.video == true { NotificationCenter.default.post(name: .photoLabPlayback, object: nil) }
                else { model.returnToGrid() }
                return nil
            case "\u{1b}": model.returnToGrid(); return nil
            default: return event
            }
        }
    }
    private func openEditor(_ asset: Asset) {
        guard !asset.video, !editor.isPresented else { return }
        let decorationBatchIDs = model.selection.contains(asset.id) ? model.selection : [asset.id]
        model.select(asset)
        model.enterSingle()
        let lookup = Dictionary(uniqueKeysWithValues: model.assets.map { ($0.id, $0) })
        var assets = model.photoNavigation.ids.compactMap { lookup[$0] }.filter { !$0.video }
        if !assets.contains(where: { $0.id == asset.id }) { assets.insert(asset, at: 0) }
        let items = assets.map { photo in
            EditablePhoto(id: photo.id, name: photo.name, sources: photo.files.compactMap { model.url(for: photo, file: $0) }, rotation: photo.quarterTurns)
        }.filter { !$0.sources.isEmpty }
        editor.onCommit = { id in model.editRevision += 1; model.scheduleAnalysisEdits(ids: [id]) }
        editor.onSelect = { id in if let current = model.assets.first(where: { $0.id == id }) { model.select(current) } }
        editor.onBatchChange = { ids in model.editRevision += 1; model.scheduleAnalysisEdits(ids: ids) }
        editor.open(items, selectedID: asset.id, batchIDs: decorationBatchIDs)
    }
    private func presentPhoto() {
        guard let asset = model.focused ?? model.filtered.first, !asset.video else { return }
        let snapshot = model.photoNavigation
        let lookup = Dictionary(uniqueKeysWithValues: model.assets.map { ($0.id, $0) })
        let entries = snapshot.ids.compactMap { lookup[$0] }.filter { !$0.video }.compactMap { item -> PhotoViewingEntry? in
            guard let url = model.url(for: item) else { return nil }
            return PhotoViewingEntry(id: item.id, name: item.name, url: url, raw: item.preferred.isRAW, cacheKey: MediaLoader.shared.key(asset: item, file: item.preferred), rotation: item.quarterTurns, rating: item.rating, editSources: PhotoEditStore.siblings(asset: item, preferred: url), asset: item)
        }
        PhotoViewingController.shared.present(entries: entries, selectedID: asset.id, navigation: snapshot, withinGroup: model.withinPhotoGroup, onNavigationMode: { model.withinPhotoGroup = $0 }, onClose: { id in
            if let current = model.assets.first(where: { $0.id == id }) { model.select(current); model.rebuild() }
        }, onRotate: { id, turns in model.rotate(id, by: turns) }, onRate: { id, rating in
            model.mark(assetID: id, rating: rating)
            return model.assets.first(where: { $0.id == id })?.rating
        })
    }
}

struct AssetTile: View {
    @EnvironmentObject var semantic: SemanticSearchModel
    @EnvironmentObject var model: LibraryModel
    let asset: Asset
    let selected: Bool
    let focused: Bool
    @State private var duration: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                Color.clear.aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .overlay { Thumbnail(asset: asset, url: model.url(for: asset)) }.clipped()
                HStack(spacing: 5) {
                    if asset.video { Label(duration.map { String(format: "%02d:%02d", Int($0) / 60, Int($0) % 60) } ?? "视频", systemImage: "play.fill") }
                    else { Text(asset.hasRAW && asset.files.count > 1 ? "\(asset.preferred.ext.uppercased()) + RAW" : asset.preferred.ext.uppercased()) }
                    Spacer()
                    if asset.flag == 1 { Image(systemName: "flag.fill").foregroundStyle(Color.accentColor) }
                    if asset.flag == -1 { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
                    if asset.missing { Image(systemName: "externaldrive.badge.exclamationmark") }
                }.font(.system(size: 10, weight: .semibold)).padding(7).background(.black.opacity(0.6))
            }.clipShape(RoundedRectangle(cornerRadius: 7))
            if let members = model.stackMembers[asset.id], members.count > 1 {
                Button { model.toggleStack(asset.id) } label: {
                    Label("\(members.count) 张相似照片 · 展开 / 收起", systemImage: "square.stack.3d.up")
                        .font(.caption).foregroundStyle(Color.accentColor)
                }.buttonStyle(.borderless)
            }
            HStack { Text(asset.name).font(.system(size: 12, weight: .medium)).lineLimit(1); Spacer(minLength: 2); Text(asset.rating > 0 ? String(repeating: "★", count: asset.rating) : "☆☆☆☆☆").font(.system(size: 10)).foregroundStyle(asset.rating > 0 ? Color.accentColor : .secondary) }
            if model.semanticIDs != nil, let score = semantic.scores[asset.id] {
                Text("\(semantic.scoreLabel) \(String(format: "%.3f", score))")
                    .font(.caption.monospacedDigit()).foregroundStyle(Color.accentColor)
                    .help(semantic.scoreHelp(asset.id))
            }
            if !asset.video {
                HStack {
                    Text(model.artScore(asset).map { "艺术 " + String(format: "%.2f", ArtScoring.display($0)) } ?? "艺术 —")
                    Text(model.qualityScore(asset).map { "质量 " + String(format: "%.2f", ArtScoring.display($0)) } ?? "质量 —")
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(asset.tags.isEmpty ? (asset.folder.isEmpty ? "根目录" : asset.folder) : asset.tags.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }.padding(9).background(selected ? Color.accentColor.opacity(0.12) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? Color.accentColor : selected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
            .task(id: asset.id) {
                guard asset.video, let url = model.url(for: asset) else { return }
                let result = await metadata(for: asset, url: url)
                if !Task.isCancelled, let text = result.first(where: { $0.0 == "时长" })?.1 { duration = Double(text.replacingOccurrences(of: " 秒", with: "")) }
            }
            .contextMenu {
                if model.stackMembers[asset.id] != nil {
                    Button("展开 / 收起相似照片") { model.toggleStack(asset.id) }
                    Button("选择整组") { model.selectStack(asset.id) }
                    Button("设为分组封面") { model.useAsStackCover(asset.id) }
                    Button("将此照片移出分组") { model.excludeFromStack(asset.id) }
                    Divider()
                }
                if model.isExcludedFromStacks(asset.id) { Button("恢复自动聚合") { model.restoreToStacks(asset.id) } }
                if !asset.video { Button("编辑照片") { NotificationCenter.default.post(name: .photoLabEdit, object: asset.id) } }
                Button("打开预览") { model.select(asset); model.enterSingle() }
                if !asset.video { Button("AI 找相似照片") { semantic.openSimilar(asset) } }
                if !asset.video {
                    Button("向左旋转 90°") { model.rotate(asset.id, by: -1) }
                    Button("向右旋转 90°") { model.rotate(asset.id, by: 1) }
                }
                Button("在 Finder 中显示") { if let url = model.url(for: asset) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            }
    }
}

struct Inspector: View {
    @EnvironmentObject var model: LibraryModel
    @State private var tagText = ""
    @State private var info: [(String, String)] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack { Text("信息与标记").font(.headline); Spacer(); Image(systemName: "sidebar.right").foregroundStyle(.secondary) }
                if let asset = model.focused {
                    Thumbnail(asset: asset, url: model.url(for: asset)).frame(height: 140).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 5) { Text(asset.name).font(.headline).textSelection(.enabled); Text(model.selection.count > 1 ? "标记应用到 \(model.selection.count) 个选中项目" : asset.video ? "视频 · 原片" : "照片 · \(asset.files.count) 个关联文件").font(.caption).foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("手动星级").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 10) { ForEach(1...5, id: \.self) { n in Button { model.mark(rating: asset.rating == n ? 0 : n) } label: { Image(systemName: asset.rating >= n ? "star.fill" : "star").font(.system(size: 20)).foregroundStyle(Color.accentColor) }.buttonStyle(.plain) } }
                        HStack { Button { model.mark(flag: asset.flag == 1 ? 0 : 1) } label: { Label("保留", systemImage: asset.flag == 1 ? "flag.fill" : "flag") }; Button { model.mark(flag: asset.flag == -1 ? 0 : -1) } label: { Label("淘汰", systemImage: "xmark") } }
                    }
                    if !asset.video {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.artScore(asset).map { "模型艺术打分 " + String(format: "%.2f / 5", ArtScoring.display($0)) } ?? "模型艺术打分 · 未评分")
                            Text(model.qualityScore(asset).map { "模型质量打分 " + String(format: "%.2f / 5", ArtScoring.display($0)) } ?? "模型质量打分 · 未评分")
                        }.font(.callout.monospacedDigit())
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("标签").font(.caption).foregroundStyle(.secondary)
                        ForEach(asset.tags, id: \.self) { tag in HStack { Label(tag, systemImage: "tag"); Spacer(); Button { model.mark(removeTag: tag) } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.font(.caption).padding(7).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5)) }
                        TextField("添加标签，逗号分隔", text: $tagText).textFieldStyle(.roundedBorder).onSubmit(addTags)
                        Button("添加标签", action: addTags).disabled(tagText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("文件信息").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(info.enumerated()), id: \.offset) { _, pair in VStack(alignment: .leading, spacing: 3) { Text(pair.0).foregroundStyle(.secondary); Text(pair.1).textSelection(.enabled) }.font(.caption) }
                        Text("文件修改时间：\(Date(timeIntervalSince1970: asset.date).formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    Text("关联原文件").font(.caption).foregroundStyle(.secondary)
                    ForEach(asset.files, id: \.relativePath) { file in
                        VStack(alignment: .leading, spacing: 5) {
                            Text((file.relativePath as NSString).lastPathComponent).font(.caption.weight(.medium)).textSelection(.enabled)
                            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                            Button("在 Finder 中显示") { if let url = model.url(for: asset, file: file) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }.font(.caption2)
                        }
                    }
                } else { Text("选择素材后查看信息。\n⌘ 点击多选，⇧ 点击连续选择。").font(.callout).foregroundStyle(.secondary).padding(.top, 20) }
            }.padding(18)
        }.background(.white.opacity(0.025))
            .task(id: model.focusID) { info = []; guard let asset = model.focused, let url = model.url(for: asset) else { return }; let result = await metadata(for: asset, url: url); if !Task.isCancelled { info = result } }
    }
    private func addTags() { let tags = tagText.components(separatedBy: CharacterSet(charactersIn: ",，")); model.mark(addTags: tags); tagText = "" }
}

struct ExportSheet: View {
    @EnvironmentObject var model: LibraryModel
    @Environment(\.dismiss) var dismiss
    @State private var onlySelected = true
    @State private var mode = ExportMode.edited
    @State private var options = PhotoExportOptions()
    var chosen: [Asset] { onlySelected ? model.selectedAssets : model.filtered }
    var files: [MediaFile] { chosen.flatMap { Exporter.files($0, mode: mode) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(mode == .edited ? "导出编辑结果" : "导出原文件").font(.title2.weight(.semibold))
            Picker("范围", selection: $onlySelected) { Text("选中项目（\(model.selectedAssets.count)）").tag(true); Text("全部筛选结果（\(model.filtered.count)）").tag(false) }.pickerStyle(.radioGroup)
            Picker("照片导出内容", selection: $mode) { ForEach(ExportMode.allCases) { Text($0.rawValue).tag($0) } }
            if mode == .edited {
                Picker("格式", selection: $options.format) {
                    ForEach(PhotoExportFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                if options.format == .jpeg {
                    HStack {
                        Text("质量")
                        Slider(value: $options.quality, in: 0.1...1, step: 0.01)
                        Text("\(Int((options.quality * 100).rounded()))%").monospacedDigit().frame(width: 45)
                    }
                    Toggle("尽可能保留 HDR", isOn: $options.preserveHDR)
                    Text("支持时使用 JPG 增益图保留 HDR；不支持时（包括 Redlamp 调色）自动导出编辑后的 SDR 照片。HDR 显示需兼容的显示器和查看器。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(mode == .edited ? "\(chosen.count) 个项目 · 全分辨率 \(options.format.rawValue)（无编辑时使用默认处理）" : "\(chosen.count) 个项目 · \(files.count) 个文件 · \(ByteCountFormatter.string(fromByteCount: files.reduce(0) { $0 + $1.size }, countStyle: .file))").font(.headline)
            Text("视频始终复制原片，不转码。保留子目录结构，同名文件自动另存。所选类型不存在的照片组将跳过；原盘必须在线。").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("取消") { dismiss() }; Button("选择导出位置…") { let snapshot = chosen; let selectedMode = mode; let selectedOptions = options; dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.export(assets: snapshot, mode: selectedMode, options: selectedOptions) } }.buttonStyle(.borderedProminent).disabled(files.isEmpty) }
        }.padding(28).frame(width: 460).onAppear { if model.selection.isEmpty { onlySelected = false } }
    }
}

extension Notification.Name { static let photoLabEdit = Notification.Name("PhotoLabEdit") }
