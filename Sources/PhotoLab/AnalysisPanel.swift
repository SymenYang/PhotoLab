import SwiftUI

struct AnalysisScope: Sendable {
    var photos: [Asset] = []
    var fingerprints: [String: String] = [:]
    var name = "所有素材"
    var identity = ""
}

struct AnalysisPanel: View {
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var semantic: SemanticSearchModel
    @ObservedObject var siglip: SemanticSearchModel
    @ObservedObject var qwen: SemanticSearchModel
    @ObservedObject var art: SemanticSearchModel
    @ObservedObject var quality: SemanticSearchModel
    @State private var scope = AnalysisScope()
    @State private var loadingScope = true
    private var scopeID: String { "\(library.contentRevision)|\(library.filter.rootID ?? "")|\(library.filter.folder ?? "")|\(library.filter.recursive)" }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("管理 / 下载 AI 模型…") { ModelDownloadManager.shared.show() }.font(.caption)
            Text(scope.name).font(.caption).lineLimit(2)
            Toggle("含子目录", isOn: $library.filter.recursive).toggleStyle(.checkbox).font(.caption)
            if loadingScope { ProgressView().controlSize(.small) }
            AnalysisRow(title: "SigLIP 检索索引", engine: siglip, scope: scope, blocked: loadingScope)
            AnalysisRow(title: "Qwen 检索索引", engine: qwen, scope: scope, blocked: loadingScope)
            AnalysisRow(title: "模型艺术打分", engine: art, scope: scope, blocked: loadingScope)
            AnalysisRow(title: "模型质量打分", engine: quality, scope: scope, blocked: loadingScope)
        }
        .task(id: scopeID) {
            loadingScope = true
            let assets = library.assets
            var filter = FilterState()
            filter.rootID = library.filter.rootID; filter.folder = library.filter.folder; filter.recursive = library.filter.recursive
            let identity = scopeID
            let name = library.filter.folder ?? library.roots.first(where: { $0.id == library.filter.rootID })?.name ?? "所有素材"
            let next = await Task.detached(priority: .utility) {
                let photos = assets.filter { !$0.video && filter.matches($0) }
                return AnalysisScope(photos: photos, fingerprints: Dictionary(uniqueKeysWithValues: photos.map { ($0.id, SemanticSearchModel.fingerprint($0)) }), name: name, identity: identity)
            }.value
            guard !Task.isCancelled else { return }
            scope = next; loadingScope = false
        }
    }
}

private struct AnalysisRow: View {
    let title: String
    @ObservedObject var engine: SemanticSearchModel
    let scope: AnalysisScope
    let blocked: Bool
    @EnvironmentObject var library: LibraryModel
    @State private var complete = 0
    @State private var failed = 0
    private var countID: String { "\(scope.identity)|\(scope.photos.count)|\(library.filter.recursive)|\(library.contentRevision)|\(engine.revision)" }
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
            Text("\(complete)/\(scope.photos.count)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            if failed > 0 || engine.error != nil {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    .help(engine.error ?? "\(failed) 张失败，右键重试")
            }
            Button {
                engine.index(library, photos: scope.photos, scopeName: scope.name)
            } label: {
                Image(systemName: "text.badge.plus").frame(width: 16, height: 18)
            }
            .disabled(blocked || scope.photos.isEmpty)
            .accessibilityLabel(title + " · 加入队列")
            .help("加入批量队列；在任务中心暂停或取消")
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.borderless)
        .contextMenu {
            Button("重试失败") { engine.index(library, photos: scope.photos, scopeName: scope.name, retryOnly: true) }
                .disabled(blocked || failed == 0)
        }
        .task(id: countID) {
            let fingerprints = engine.fingerprints, failures = engine.failedIDs, backend = engine.backend, keys = scope.fingerprints
            let counts = await Task.detached(priority: .utility) {
                var done = 0, failed = 0
                for (id, key) in keys {
                    let expected = backend == "quality" ? key + "-q-realign-fe1f45a-iqa-768-v1" : backend == "art" ? key + "-q-realign-fe1f45a-iaa-768-v1" : key
                    if fingerprints[id] == expected { done += 1 }
                    else if failures.contains(id) { failed += 1 }
                }
                return (done, failed)
            }.value
            guard !Task.isCancelled else { return }
            complete = counts.0; failed = counts.1
        }
    }
}
