import SwiftUI

struct RuleFilterPanel: View {
    @EnvironmentObject var library: LibraryModel
    @ObservedObject var embeddings: RuleEmbeddingSearchModel
    let save: () -> Void
    private var rows: [FilterRule] { library.filter.effectiveRules }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { var next = rows; next.append(FilterRule()); library.filter.setRules(next) } label: {
                    Label("添加规则", systemImage: "plus")
                }
                Toggle("含子目录", isOn: $library.filter.recursive).toggleStyle(.checkbox)
                Text("AND 优先于 OR").foregroundStyle(.secondary)
                    .help("A OR B AND C 表示 A OR (B AND C)。目录范围始终生效；顶部 AI 搜索与整组规则取交集。")
                Spacer(minLength: 0)
                Button(action: save) { Image(systemName: "bookmark") }.help("保存整组筛选规则")
                Button { library.filter.setRules([]) } label: { Image(systemName: "arrow.counterclockwise") }
                    .help("清除规则，保留目录范围和排序").disabled(rows.isEmpty)
            }.font(.caption)
            if !rows.isEmpty {
                ScrollView(.vertical) {
                    VStack(spacing: 6) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, rule in
                            RuleFilterRow(rule: binding(rule.id), first: index == 0, embeddings: embeddings) {
                                library.filter.setRules(rows.filter { $0.id != rule.id })
                            }
                            .contextMenu {
                                Button("上移") { move(index, by: -1) }.disabled(index == 0)
                                Button("下移") { move(index, by: 1) }.disabled(index == rows.count - 1)
                            }
                        }
                    }.padding(.vertical, 2)
                }.frame(height: min(CGFloat(rows.count) * 34 + 4, 240))
            }
        }.padding(.horizontal, 20).padding(.bottom, 12)
    }
    private func binding(_ id: String) -> Binding<FilterRule> {
        Binding(get: { rows.first { $0.id == id } ?? FilterRule(id: id) }, set: { value in
            var next = rows
            guard let index = next.firstIndex(where: { $0.id == id }) else { return }
            next[index] = value; library.filter.setRules(next)
        })
    }
    private func move(_ index: Int, by offset: Int) {
        var next = rows; let destination = index + offset
        guard next.indices.contains(destination) else { return }
        next.swapAt(index, destination); library.filter.setRules(next)
    }
}

private struct RuleFilterRow: View {
    @Binding var rule: FilterRule
    let first: Bool
    @ObservedObject var embeddings: RuleEmbeddingSearchModel
    let remove: () -> Void
    private var status: String? {
        guard rule.enabled else { return nil }
        if let validation = rule.validation { return validation }
        guard let query = rule.embeddingQuery else { return nil }
        if let error = embeddings.errors[query] { return error }
        if let notice = embeddings.notices[query] { return notice }
        if embeddings.counts[query] == 0 { return "当前目录没有有效 embedding；可在左侧 AI 分析建立索引。" }
        return nil
    }
    var body: some View {
        HStack(spacing: 6) {
            Toggle("启用规则", isOn: $rule.enabled).labelsHidden().toggleStyle(.checkbox)
            if first { Text("满足").foregroundStyle(.secondary).frame(width: 60) }
            else {
                Picker("连接方式", selection: $rule.join) {
                    ForEach(FilterJoin.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 60)
            }
            Picker("字段", selection: Binding(get: { rule.field }, set: { rule.select($0) })) {
                ForEach(FilterField.allCases, id: \.self) { Text($0.title).tag($0) }
            }.labelsHidden().frame(width: 140)
            if rule.field.isEmbedding {
                TextField("描述画面", text: $rule.query).textFieldStyle(.roundedBorder)
                    .frame(minWidth: 80).accessibilityLabel("embedding 描述")
                    .help(rule.field == .fusion ? "混合相关度为当前目录内的排名融合值（0–1），不是余弦相似度。" : "此模型对描述词的余弦相似度（−1–1）。")
            }
            Picker("比较方式", selection: $rule.comparison) {
                ForEach(rule.field.comparisons, id: \.self) { Text($0.title).tag($0) }
            }.labelsHidden().frame(width: 76)
            if rule.comparison.needsValue {
                valueEditor
                if rule.field.isNumeric && !rule.field.isEmbedding { Spacer(minLength: 0) }
            } else { Spacer(minLength: 0) }
            if let query = rule.embeddingQuery, rule.enabled, embeddings.pending.contains(query) {
                ProgressView().controlSize(.mini).frame(width: 16).help("正在计算这条规则的相似度")
            } else if let status {
                Button { if rule.embeddingQuery != nil { embeddings.retryRevision += 1 } } label: {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                }.buttonStyle(.plain).help(status).accessibilityLabel(status)
            }
            Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("删除规则")
        }.font(.caption).controlSize(.small).frame(height: 28)
            .opacity(rule.enabled ? 1 : 0.5)
    }
    @ViewBuilder private var valueEditor: some View {
        if rule.field == .kind {
            Picker("类型", selection: $rule.value) { Text("照片").tag("photo"); Text("视频").tag("video") }.labelsHidden()
        } else if rule.field == .flag {
            Picker("状态", selection: $rule.value) { Text("保留").tag("1"); Text("未决定").tag("0"); Text("淘汰").tag("-1") }.labelsHidden()
        } else {
            TextField(rule.field.isNumeric ? "阈值" : "条件值", text: $rule.value)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: rule.field.isNumeric ? 58 : 80, maxWidth: rule.field.isNumeric ? 70 : .infinity)
                .accessibilityLabel(rule.field.isNumeric ? "比较阈值" : "条件值")
                .help(rule.field == .art || rule.field == .quality ? "与卡片显示的 5 分制分数比较（保留两位小数）" : "")
        }
    }
}
