import Foundation

struct LibrarySummary {
    var tags: [String] = []
    var bytes: Int64 = 0
    var folders: [String: [String]] = [:]
    var counts: [String: Int] = [:]
    static func make(_ assets: [Asset]) -> Self {
        var tags = Set<String>(); var paths: [String: Set<String>] = [:]; var result = Self()
        for a in assets {
            tags.formUnion(a.tags); result.bytes += a.bytes; result.counts[a.rootID, default: 0] += 1
            var path = a.folder
            while !path.isEmpty {
                if paths[a.rootID, default: []].contains(path) { break }
                paths[a.rootID, default: []].insert(path); path = (path as NSString).deletingLastPathComponent
            }
        }
        result.tags = tags.sorted()
        result.folders = paths.mapValues { $0.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
        return result
    }
}
enum LibraryQuery {
    static func run(_ assets: [Asset], filter: FilterState, dates: Bool, semantic: [String]?, artScores: [String: Double] = [:], ruleScores: FilterScoreContext = FilterScoreContext(), cancelled: () -> Bool = { false }) -> [Asset] {
        var matched: [Asset] = []
        for (i,a) in assets.enumerated() {
            if i % 1024 == 0 && cancelled() { return [] }
            if filter.matches(a, scores: ruleScores) { matched.append(a) }
        }
        let days = dates ? Dictionary(uniqueKeysWithValues: matched.map { ($0.id, CaptureDates.day($0.captureDate)) }) : [:]
        let semanticRanks = semantic.map { Dictionary($0.enumerated().map { ($0.element,$0.offset) }, uniquingKeysWith: { first,_ in first }) }
        if let semantic, !dates {
            let lookup = Dictionary(uniqueKeysWithValues: matched.map { ($0.id,$0) })
            return semantic.compactMap { lookup[$0] }
        }
        if let semanticRanks { matched = matched.filter { semanticRanks[$0.id] != nil } }
        var comparisons = 0
        return (try? matched.sorted { a,b in
            comparisons += 1
            if comparisons % 1024 == 0 && cancelled() { throw CancellationError() }
            if dates, let left = days[a.id], let right = days[b.id], left != right {
                if left == "未知拍摄日期" { return false }
                if right == "未知拍摄日期" { return true }
                return left > right
            }
            if let ranks = semanticRanks { return ranks[a.id, default: Int.max] < ranks[b.id, default: Int.max] }
            if ["artHigh","artLow","qualityHigh","qualityLow"].contains(filter.sort) {
                let left = artScores[a.id], right = artScores[b.id]
                if left != right {
                    guard let left else { return false }
                    guard let right else { return true }
                    return (filter.sort == "artHigh" || filter.sort == "qualityHigh") ? left > right : left < right
                }
            }
            if filter.sort == "rating" && a.rating != b.rating { return a.rating > b.rating }
            if filter.sort == "date" && a.date != b.date { return a.date > b.date }
            if a.folder != b.folder { return a.folder.localizedStandardCompare(b.folder) == .orderedAscending }
            if a.name != b.name { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return a.id < b.id
        }) ?? []
    }
}


// Section boundaries preserve partial rows at date-group transitions.
enum GridNavigation {
    static func sections(_ assets: [Asset], grouped: Bool) -> [Range<Int>] {
        guard !assets.isEmpty else { return [] }
        guard grouped else { return [0..<assets.count] }
        var result: [Range<Int>] = [], start = 0
        var day = CaptureDates.day(assets[0].captureDate)
        for i in 1..<assets.count {
            let next = CaptureDates.day(assets[i].captureDate)
            if next != day { result.append(start..<i); start = i; day = next }
        }
        result.append(start..<assets.count)
        return result
    }
    static func target(current: Int, columns: Int, direction: Int, sections: [Range<Int>]) -> Int {
        guard let section = sections.firstIndex(where: { $0.contains(current) }) else { return current }
        let range = sections[section], width = max(1, columns)
        let offset = current - range.lowerBound, column = offset % width, row = offset / width
        if direction > 0 {
            let next = range.lowerBound + (row + 1)*width
            if next < range.upperBound { return min(next + column, range.upperBound-1) }
            if section+1 < sections.count {
                let nextRange = sections[section+1]
                return min(nextRange.lowerBound+column,nextRange.upperBound-1)
            }
        } else {
            if row > 0 { return range.lowerBound + (row-1)*width + column }
            if section > 0 {
                let previous = sections[section-1]
                let lastRow = previous.lowerBound + ((previous.count-1)/width)*width
                return min(lastRow+column,previous.upperBound-1)
            }
        }
        return current
    }
}

struct SimilarityProjection {
    var assets: [Asset] = []
    var members: [String: [Asset]] = [:]
    var keys: [String: String] = [:]
    var navigation = PhotoNavigationSnapshot()
    static func make(_ ordered: [Asset], groups: [String: String], fingerprints: [String: String], excluded: Set<String>, covers: Set<String>, expanded: Set<String>, preserve: Set<String>, enabled: Bool) -> Self {
        guard enabled else { return Self(assets: ordered, navigation: PhotoNavigationSnapshot(groups: ordered.map { [$0.id] }, covers: ordered.map(\.id))) }
        var buckets: [String: [Asset]] = [:]
        var keys: [String: String] = [:]
        for asset in ordered {
            guard !asset.video, !excluded.contains(asset.id), let key = groups[asset.id], fingerprints[asset.id] == asset.analysisFingerprint else { continue }
            buckets[key, default: []].append(asset); keys[asset.id] = key
        }
        var result = Self(), emitted = Set<String>()
        for asset in ordered {
            guard let key = keys[asset.id], let members = buckets[key], members.count > 1 else { result.assets.append(asset); result.navigation.groups.append([asset.id]); result.navigation.covers.append(asset.id); continue }
            guard emitted.insert(key).inserted else { continue }
            let cover = members.first { covers.contains($0.id) } ?? members[0]
            let open = expanded.contains(key) || members.contains { preserve.contains($0.id) && $0.id != cover.id }
            // Group position follows its best-ranked member, independently of a manual cover.
            result.navigation.groups.append(members.map(\.id)); result.navigation.covers.append(cover.id)
            result.assets.append(contentsOf: open ? members : [cover])
            for member in members { result.members[member.id] = members; result.keys[member.id] = key }
        }
        return result
    }
}

// Immutable per-viewing-session order. Current scores and marks remain live.
struct PhotoNavigationSnapshot {
    var groups: [[String]] = []
    var covers: [String] = []
    var ids: [String] { groups.flatMap { $0 } }
    func position(_ id: String?) -> (group: Int, member: Int)? {
        guard let id else { return nil }
        for (g, members) in groups.enumerated() { if let m = members.firstIndex(of: id) { return (g, m) } }
        return nil
    }
    func target(from id: String?, offset: Int, withinGroup: Bool) -> String? {
        guard let p = position(id) else { return nil }
        if withinGroup {
            let next = p.member + offset
            return groups[p.group].indices.contains(next) ? groups[p.group][next] : nil
        }
        let next = p.group + offset
        return covers.indices.contains(next) ? covers[next] : nil
    }
    func label(for id: String?) -> String {
        guard let p = position(id) else { return "" }
        return "第 \(p.group + 1) / \(groups.count) 组 · 本组 \(p.member + 1) / \(groups[p.group].count)"
    }
    func keeping(_ allowed: Set<String>) -> Self {
        var result = Self()
        for (i, members) in groups.enumerated() {
            let kept = members.filter { allowed.contains($0) }
            guard let first = kept.first else { continue }
            result.groups.append(kept); result.covers.append(kept.contains(covers[i]) ? covers[i] : first)
        }
        return result
    }
}
