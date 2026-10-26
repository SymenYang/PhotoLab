import Foundation
func check(_ result: Bool, _ message: String) { precondition(result, message) }
func photo(_ id: String, tags: [String] = [], rating: Int = 0) -> Asset {
    var asset = Asset(id: id, rootID: "root", folder: "trip", name: id, video: false,
                      files: [MediaFile(relativePath: id + ".jpg", size: 1, modified: 1)], date: 1)
    asset.tags = tags; asset.rating = rating; return asset
}
let a = photo("a", tags: ["旅行", "人像"], rating: 5)
let b = photo("b", tags: ["旅行"], rating: 2)
let c = photo("c", tags: ["风景"], rating: 4)
let d = photo("d", rating: 0)
let assets = [a, b, c, d]
let beach = EmbeddingFilterQuery(backend: "siglip", text: "海边")
let portrait = EmbeddingFilterQuery(backend: "qwen", text: "人像")
let scores = FilterScoreContext(art: ["a": 4.8, "b": 3.5, "c": 4.2], quality: ["a": 3, "b": 4.5, "c": 4.8],
                               embeddings: [beach: ["a": 0.2, "b": 0.7], portrait: ["a": 0.8, "c": 0.1]])
func ids(_ rows: [FilterRule], context: FilterScoreContext = scores) -> [String] {
    var filter = FilterState(); filter.setRules(rows)
    return LibraryQuery.run(assets, filter: filter, dates: false, semantic: nil, ruleScores: context).map(\.id)
}
let art = FilterRule(field: .art, value: "4")
let quality = FilterRule(field: .quality, value: "4")
let tag = FilterRule(field: .tag, comparison: .equal, value: "旅行")
check(ids([art, quality]) == ["c"], "AND of independent AI scores")
var orQuality = quality; orQuality.join = .or
check(ids([art, orQuality]) == ["a", "b", "c"], "OR must preserve candidates from either score")
check(ids([tag, FilterRule(join: .or, field: .art, value: "4"), quality]) == ["a", "b", "c"], "AND before OR, not left-fold")
let siglip = FilterRule(field: .siglip, comparison: .greaterEqual, value: "0.5", query: "海边")
let qwen = FilterRule(join: .or, field: .qwen, comparison: .greater, value: "0.5", query: "人像")
check(ids([siglip, qwen]) == ["a", "b"], "independent embedding queries with partial coverage")
check(ids([siglip, FilterRule(join: .or, field: .tag, comparison: .equal, value: "风景")]) == ["b", "c"], "OR tag must include a photo without embedding")
check(ids([FilterRule(field: .art, comparison: .less, value: "4")]) == ["b"], "missing score is not zero")
check(ids([FilterRule(field: .art, comparison: .notEqual, value: "4")]) == ["a", "b", "c"], "missing score is not unequal")
check(ids([FilterRule(field: .art, comparison: .missing)]) == ["d"], "explicit unscored filter")
check(ids([FilterRule(field: .siglip, comparison: .missing, query: "海边")]) == ["c", "d"], "known missing embeddings")
check(ids([FilterRule(field: .siglip, comparison: .missing, query: "海边")], context: FilterScoreContext()).isEmpty, "pending/failed query is not a known missing vector")
check(ids([FilterRule(field: .art, value: "NaN")]).isEmpty, "invalid threshold must not match")
var disabled = art; disabled.enabled = false
check(ids([disabled]) == ["a", "b", "c", "d"], "disabled rules are ignored")
check(ids([FilterRule(field: .tag, comparison: .notContains, value: "旅行")]) == ["c", "d"], "negative tag match")
check(ids([FilterRule(field: .rating, comparison: .equal, value: "0")]) == ["d"], "zero is a valid rating")
var scoped = FilterState(); scoped.rootID = "other"; scoped.setRules([art, orQuality])
check(!scoped.matches(a, scores: scores), "OR must never escape folder/root scope")
var filter = FilterState(); filter.setRules([siglip, qwen])
check(LibraryQuery.run(assets, filter: filter, dates: false, semantic: ["b", "c", "a"], ruleScores: scores).map(\.id) == ["b", "a"], "top search intersects rules and retains rank")
let data = try JSONEncoder().encode(SavedFilter(name: "组合", state: filter))
let decoded = try JSONDecoder().decode(SavedFilter.self, from: data)
check(decoded.state == filter, "rule presets round-trip")
let oldJSON = Data(#"{"search":"旅行","rating":2,"kind":"photo","flag":"all","tag":"","recursive":true,"sort":"name"}"#.utf8)
var legacy = try JSONDecoder().decode(FilterState.self, from: oldJSON)
check(legacy.matches(a) && legacy.matches(b) && !legacy.matches(c), "old preset semantics including tag search")
legacy.setRules(legacy.effectiveRules)
check(legacy.matches(a) && legacy.matches(b) && !legacy.matches(c), "legacy conversion preserves matches")
filter.setRules([siglip, siglip]); check(filter.embeddingQueries.count == 1, "identical embedding queries are deduplicated")
filter.toggleTag("旅行"); check(filter.hasTag("旅行"), "sidebar tag adds a rule")
filter.toggleTag("旅行"); check(!filter.hasTag("旅行"), "sidebar tag removes rule")
print("PASS filter rules: AND/OR precedence, AI scores, independent embeddings, missing values, metadata, scope, presets, legacy conversion")
