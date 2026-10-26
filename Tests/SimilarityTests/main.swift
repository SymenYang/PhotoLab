import Foundation
func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
func photo(_ id: String) -> Asset { Asset(id: id, rootID: "r", folder: "", name: id, video: false, files: [MediaFile(relativePath: id + ".jpg", size: 10, modified: 1)], date: 1) }
let a = photo("a"), b = photo("b"), c = photo("c")
let all = [a, b, c]
let fingerprints = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.analysisFingerprint) })
func project(_ assets: [Asset] = all, excluded: Set<String> = [], covers: Set<String> = [], expanded: Set<String> = [], preserve: Set<String> = [], enabled: Bool = true) -> SimilarityProjection {
    SimilarityProjection.make(assets, groups: ["a": "g", "b": "g"], fingerprints: fingerprints, excluded: excluded, covers: covers, expanded: expanded, preserve: preserve, enabled: enabled)
}
check(project().assets.map(\.id) == ["a", "c"], "collapsed")
check(all.count == 3, "source/export scope changed")
check(project(expanded: ["g"]).assets.map(\.id) == ["a", "b", "c"], "expand")
check(project(preserve: ["b"]).assets.map(\.id) == ["a", "b", "c"], "focused member hidden")
check(project(covers: ["b"]).assets.map(\.id) == ["b", "c"], "manual cover")
check(project([b, c]).assets.map(\.id) == ["b", "c"], "filtered cover hides remaining member")
check(project([b, a, c]).assets.map(\.id) == ["b", "c"], "sort ignored")
check(project(excluded: ["a"]).assets.count == 3, "manual exclusion")
check(project(enabled: false).assets.count == 3, "search/disabled aggregation")
var changed = b; changed.rotation = 1
check(project([a, changed, c]).assets.count == 3, "stale vector hid changed photo")
let rows = GridNavigation.sections(project().assets, grouped: false)
check(GridNavigation.target(current: 0, columns: 1, direction: 1, sections: rows) == 1, "collapsed grid navigation")
print("PASS similarity projection: collapse, expand, selection, covers, filters, sort, exclusions, search, invalidation, navigation")

// Scores affect ordering, never similarity membership. Manual covers do not rank a group.
var rankedFilter = FilterState(); rankedFilter.sort = "artHigh"
let ranked = LibraryQuery.run(all, filter: rankedFilter, dates: false, semantic: nil, artScores: ["a": 4.8, "b": 3.6, "c": 4.5])
let high = project(ranked, covers: ["b"], expanded: ["g"])
check(high.assets.map(\.id) == ["a", "b", "c"], "expanded members must stay together in score order")
check(high.navigation.covers == ["b", "c"], "manual cover changed group rank")
rankedFilter.sort = "artLow"
let low = project(LibraryQuery.run(all, filter: rankedFilter, dates: false, semantic: nil, artScores: ["a": 4.8, "b": 3.6, "c": 4.5]))
check(low.assets.map(\.id) == ["b", "c"], "ascending group score")
let partial = project(LibraryQuery.run(all, filter: rankedFilter, dates: false, semantic: nil, artScores: ["a": 4.8, "c": 4.5]))
check(partial.assets.map(\.id) == ["c", "a"], "unscored member used as minimum")
let nav = high.navigation
check(nav.target(from: "a", offset: 1, withinGroup: true) == "b", "intra-group navigation")
check(nav.target(from: "b", offset: 1, withinGroup: true) == nil, "intra-group crossed boundary")
check(nav.target(from: "a", offset: -1, withinGroup: true) == nil, "intra-group wrapped")
check(nav.target(from: "b", offset: 1, withinGroup: false) == "c", "inter-group did not skip members")
check(nav.target(from: "c", offset: -1, withinGroup: false) == "b", "inter-group ignored manual cover")
check(nav.keeping(["a", "c"]).covers == ["a", "c"], "unavailable fullscreen cover fallback")
check(nav.label(for: "b") == "第 1 / 2 组 · 本组 2 / 2", "group position label")
print("PASS score-based group ordering and intra/inter-group navigation")
