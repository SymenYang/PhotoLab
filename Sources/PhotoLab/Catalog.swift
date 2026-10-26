import Foundation
import CSQLite
import ImageIO
import CryptoKit

struct LibraryRoot: Codable, Identifiable, Hashable {
    var id: String
    var path: String
    var bookmark: Data?
    var removed: Bool?
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}
struct MediaFile: Codable, Hashable {
    var relativePath: String
    var size: Int64
    var modified: Double
    // Extract metadata from the path string without probing the filesystem.
    var ext: String { (relativePath as NSString).pathExtension.lowercased() }
    var isRAW: Bool { Scanner.rawExtensions.contains(ext) }
}
struct Asset: Codable, Identifiable, Hashable {
    var id: String
    var rootID: String
    var folder: String
    var name: String
    var video: Bool
    var files: [MediaFile]
    var date: Double
    var rating = 0
    var flag = 0 // -1 reject, 0 undecided, 1 pick
    var tags: [String] = []
    var missing = false
    // Optional fields keep existing catalog JSON readable without a destructive migration.
    var captureDate: Double?
    var captureDateChecked: Bool?
    var rotation: Int?
    var analysisEditToken: String?
    var removedFromLibrary: Bool?
    var analysisTracksEdits: Bool?
    // Preserve cache and embedding fingerprints when a root expands to its parent.
    var identityPaths: [String: String]?
    func identityPath(_ file: MediaFile) -> String { identityPaths?[file.relativePath] ?? file.relativePath }
    var quarterTurns: Int { ((rotation ?? 0) % 4 + 4) % 4 }
    var preferred: MediaFile { files.first(where: { !$0.isRAW }) ?? files[0] }
    var analysisFingerprint: String {
        let entries = files.map { "\(identityPath($0))|\($0.size)|\($0.modified)" }.joined(separator: "\n")
        let legacy = SHA256.hash(data: Data("\(id)|\(entries)|\(quarterTurns)|imageio-sdr-srgb-512-rotation-v1".utf8)).map { String(format: "%02x", $0) }.joined()
        // Preserve existing model results until the actual edited content changes.
        return analysisEditToken.map { legacy + "-edit-" + $0 } ?? legacy
    }
    var qualityFingerprint: String { analysisFingerprint + "-q-realign-fe1f45a-iqa-768-v1" }
    var artFingerprint: String { analysisFingerprint + "-q-realign-fe1f45a-iaa-768-v1" }
    var hasRAW: Bool { files.contains(where: \.isRAW) }
    var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
}
struct Marks: Equatable {
    var rating: Int
    var flag: Int
    var tags: [String]
    var rotation: Int?
    init(_ asset: Asset) { rating = asset.rating; flag = asset.flag; tags = asset.tags; rotation = asset.rotation }
    func apply(to asset: inout Asset) { asset.rating = rating; asset.flag = flag; asset.tags = tags; asset.rotation = rotation }
}
struct CatalogError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class Catalog: @unchecked Sendable {
    // All application writes and startup reads use one ordered background lane.
    static let work = DispatchQueue(label: "photolab.catalog", qos: .userInitiated)
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    let directory: URL
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard sqlite3_open_v2(directory.appendingPathComponent("catalog.sqlite").path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw CatalogError(message: "无法打开本地图录数据库") }
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS roots(id TEXT PRIMARY KEY, data BLOB NOT NULL); CREATE TABLE IF NOT EXISTS assets(id TEXT PRIMARY KEY, root TEXT NOT NULL, data BLOB NOT NULL); CREATE INDEX IF NOT EXISTS assets_root ON assets(root); CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, data BLOB NOT NULL);")
    }
    deinit { sqlite3_close(db) }
    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CatalogError(message: String(cString: sqlite3_errmsg(db))) }
    }
    private func run(_ sql: String, texts: [String] = [], data: Data? = nil) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw CatalogError(message: String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, text) in texts.enumerated() { sqlite3_bind_text(statement, Int32(i + 1), text, -1, transient) }
        if let data { _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, Int32(texts.count + 1), $0.baseAddress, Int32(data.count), transient) } }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CatalogError(message: String(cString: sqlite3_errmsg(db))) }
    }
    private func read<T: Decodable>(_ sql: String, as: T.Type) throws -> [T] {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw CatalogError(message: String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(s) }
        var result: [T] = []
        while true {
            let status = sqlite3_step(s)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let ptr = sqlite3_column_blob(s, 0) else { throw CatalogError(message: "数据库读取失败") }
            result.append(try JSONDecoder().decode(T.self, from: Data(bytes: ptr, count: Int(sqlite3_column_bytes(s, 0)))))
        }
        return result
    }
    func allRoots() throws -> [LibraryRoot] { lock.lock(); defer { lock.unlock() }; return try read("SELECT data FROM roots ORDER BY rowid", as: LibraryRoot.self) }
    func roots() throws -> [LibraryRoot] { try allRoots().filter { $0.removed != true } }
    func assets() throws -> [Asset] { lock.lock(); defer { lock.unlock() }; return try read("SELECT a.data FROM assets a LEFT JOIN roots r ON a.root=r.id WHERE COALESCE(json_extract(r.data, '$.removed'),0)=0 AND COALESCE(json_extract(a.data, '$.removedFromLibrary'),0)=0", as: Asset.self) }
    func save(root: LibraryRoot) throws { lock.lock(); defer { lock.unlock() }; try run("INSERT OR REPLACE INTO roots VALUES(?,?)", texts: [root.id], data: JSONEncoder().encode(root)) }
    func save(assets: [Asset]) throws {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            for asset in assets {
                try run("INSERT OR REPLACE INTO assets VALUES(?,?,?)", texts: [asset.id, asset.rootID], data: JSONEncoder().encode(asset))
                if indexed { try index(asset) }
            }
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }
    func saveFilters(_ filters: [SavedFilter]) throws { lock.lock(); defer { lock.unlock() }; try run("INSERT OR REPLACE INTO settings VALUES(?,?)", texts: ["filters"], data: JSONEncoder().encode(filters)) }
    func filters() throws -> [SavedFilter] { lock.lock(); defer { lock.unlock() }; return try read("SELECT data FROM settings WHERE key='filters'", as: [SavedFilter].self).first ?? [] }
    private var indexed = false
    func prepareIndexes() throws {
        lock.lock(); defer { lock.unlock() }
        if indexed { return }
        // SQLite backup includes committed WAL data. Keep the legacy JSON schema readable.
        let backupURL = directory.appendingPathComponent("catalog-before-scale.sqlite")
        if !FileManager.default.fileExists(atPath: backupURL.path) {
            var target: OpaquePointer?
            guard sqlite3_open(backupURL.path, &target) == SQLITE_OK else { throw CatalogError(message: "无法备份图录") }
            defer { sqlite3_close(target) }
            guard let backup = sqlite3_backup_init(target, "main", db, "main") else { throw CatalogError(message: "无法创建图录备份") }
            let status = sqlite3_backup_step(backup, -1); sqlite3_backup_finish(backup)
            guard status == SQLITE_DONE else { try? FileManager.default.removeItem(at: backupURL); throw CatalogError(message: "图录备份未完成") }
        }
        try exec("CREATE TABLE IF NOT EXISTS asset_fields(id TEXT PRIMARY KEY, root TEXT, folder TEXT, name TEXT, rating INTEGER, flag INTEGER, video INTEGER, date REAL, capture REAL); CREATE INDEX IF NOT EXISTS fields_scope ON asset_fields(root,folder); CREATE INDEX IF NOT EXISTS fields_rating ON asset_fields(rating); CREATE INDEX IF NOT EXISTS fields_date ON asset_fields(capture); CREATE TABLE IF NOT EXISTS asset_tags(id TEXT, tag TEXT, PRIMARY KEY(id,tag)); CREATE INDEX IF NOT EXISTS tags_lookup ON asset_tags(tag,id); CREATE TABLE IF NOT EXISTS scan_state(root TEXT PRIMARY KEY,data BLOB NOT NULL); CREATE TABLE IF NOT EXISTS scan_aliases(id TEXT PRIMARY KEY, data BLOB NOT NULL);")
        let ready: [Bool] = try read("SELECT data FROM settings WHERE key='scale-index-v1'", as: Bool.self)
        if ready.first != true {
            try exec("BEGIN IMMEDIATE")
            do {
                for asset in try assets() { try index(asset) }
                try run("INSERT OR REPLACE INTO settings VALUES(?,?)", texts: ["scale-index-v1"], data: JSONEncoder().encode(true))
                try exec("COMMIT")
            } catch { try? exec("ROLLBACK"); throw error }
        }
        indexed = true
    }
    private func index(_ a: Asset) throws {
        try run("INSERT OR REPLACE INTO asset_fields VALUES(?,?,?,?,?,?,?,?,?)", texts: [a.id,a.rootID,a.folder,a.name,String(a.rating),String(a.flag),a.video ? "1":"0",String(a.date),a.captureDate.map { String($0) } ?? ""])
        try run("DELETE FROM asset_tags WHERE id=?", texts: [a.id])
        for tag in a.tags { try run("INSERT OR IGNORE INTO asset_tags VALUES(?,?)", texts: [a.id,tag]) }
    }
    func asset(_ id: String) throws -> Asset? {
        lock.lock(); defer { lock.unlock() }
        let safe = id.replacingOccurrences(of: "'", with: "''")
        return try read("SELECT data FROM assets WHERE id='\(safe)'", as: Asset.self).first
    }
    func saveMarks(_ changes: [String: Marks]) throws {
        lock.lock(); defer { lock.unlock() }
        let updated = try changes.compactMap { id, marks -> Asset? in
            guard var a = try asset(id) else { return nil }; marks.apply(to: &a); return a
        }
        try save(assets: updated)
    }
    func saveDates(_ changes: [Asset]) throws {
        lock.lock(); defer { lock.unlock() }
        let updated = try changes.compactMap { incoming -> Asset? in
            guard var a = try asset(incoming.id), a.files == incoming.files else { return nil }
            a.captureDate = incoming.captureDate; a.captureDateChecked = incoming.captureDateChecked; return a
        }
        try save(assets: updated)
    }
    func saveAnalysisEdits(_ changes: [Asset]) throws {
        lock.lock(); defer { lock.unlock() }
        let updated = try changes.compactMap { incoming -> Asset? in
            guard var a = try asset(incoming.id), a.files == incoming.files else { return nil }
            a.analysisEditToken = incoming.analysisEditToken; a.analysisTracksEdits = incoming.analysisTracksEdits
            return a
        }
        try save(assets: updated)
    }
    func mergeScan(_ incoming: [Asset]) throws -> [Asset] {
        lock.lock(); defer { lock.unlock() }
        let updated = try incoming.map { next -> Asset in
            var a = next
            let safe = next.id.replacingOccurrences(of: "'", with: "''")
            if indexed, let alias = try read("SELECT data FROM scan_aliases WHERE id='\(safe)'", as: String.self).first { a.id = alias }
            if let old = try asset(a.id) {
                a.identityPaths = old.identityPaths
                Marks(old).apply(to: &a)
                if old.files == a.files { a.captureDate = old.captureDate; a.captureDateChecked = old.captureDateChecked; a.analysisEditToken = old.analysisEditToken; a.analysisTracksEdits = old.analysisTracksEdits }
            }
            return a
        }
        try save(assets: updated); return updated
    }
    // Directory edits are local, transactional catalog changes. Original files are never touched.
    func directoryBackup() throws {
        let url = directory.appendingPathComponent("catalog-before-directory-" + UUID().uuidString + ".sqlite")
        var target: OpaquePointer?
        guard sqlite3_open(url.path, &target) == SQLITE_OK else { throw CatalogError(message: "无法备份图录") }
        defer { sqlite3_close(target) }
        guard let backup = sqlite3_backup_init(target, "main", db, "main") else { throw CatalogError(message: "无法创建目录修改备份") }
        let status = sqlite3_backup_step(backup, -1); sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE else { try? FileManager.default.removeItem(at: url); throw CatalogError(message: "目录修改备份未完成") }
    }
    func removeFolder(rootID: String, folder: String) throws {
        guard !folder.isEmpty, !folder.hasPrefix("/"), !folder.split(separator: "/").contains("..") else {
            throw CatalogError(message: "请选择有效的子目录")
        }
        lock.lock(); defer { lock.unlock() }
        try prepareIndexes(); try directoryBackup()
        let removed = try assets().filter { $0.rootID == rootID && ($0.folder == folder || $0.folder.hasPrefix(folder + "/")) }
        try exec("BEGIN IMMEDIATE")
        do {
            for var asset in removed {
                asset.removedFromLibrary = true
                try run("UPDATE assets SET data=? WHERE id='\(asset.id.replacingOccurrences(of: "'", with: "''"))'", texts: [], data: JSONEncoder().encode(asset))
            }
            try run("DELETE FROM scan_state WHERE root=?", texts: [rootID])
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }

    func updateDirectory(_ target: LibraryRoot, removing: Bool = false) throws {
        lock.lock(); defer { lock.unlock() }
        try prepareIndexes(); try directoryBackup()
        let others = try allRoots().filter { $0.id != target.id }
        guard !others.contains(where: { $0.removed != true && DirectoryPaths.relative(target.path, to: $0.path) != nil }) else {
            throw CatalogError(message: "该目录已包含在现有图库目录中")
        }
        let covered = others.filter { DirectoryPaths.relative($0.path, to: target.path) != nil || ($0.removed == true && DirectoryPaths.relative(target.path, to: $0.path) != nil) }
        try exec("BEGIN IMMEDIATE")
        do {
            var root = target; root.removed = removing
            try save(root: root)
            if !removing {
                for oldRoot in covered {
                    let prefix = DirectoryPaths.relative(oldRoot.path, to: target.path)
                    let safe = oldRoot.id.replacingOccurrences(of: "'", with: "''")
                    for var a in try read("SELECT data FROM assets WHERE root='\(safe)'", as: Asset.self) {
                        guard let folder = DirectoryPaths.relative(DirectoryPaths.join(oldRoot.path, a.folder), to: target.path) else { continue }
                        let oldFiles = a.files
                        a.rootID = target.id; a.folder = folder
                        func movedPath(_ file: MediaFile) -> String { DirectoryPaths.relative(DirectoryPaths.join(oldRoot.path, file.relativePath), to: target.path)! }
                        a.identityPaths = Dictionary(uniqueKeysWithValues: oldFiles.map { (movedPath($0), a.identityPath($0)) })
                        a.files = oldFiles.map { var f = $0; f.relativePath = movedPath(f); return f }
                        let canonical = Scanner.assetID(root: target.id, folder: a.folder, stem: a.video ? URL(fileURLWithPath: a.preferred.relativePath).lastPathComponent : a.name, video: a.video)
                        try run("INSERT OR REPLACE INTO scan_aliases VALUES(?,?)", texts: [canonical], data: JSONEncoder().encode(a.id))
                        try run("UPDATE assets SET root=?,data=? WHERE id='\(a.id.replacingOccurrences(of: "'", with: "''"))'", texts: [target.id], data: JSONEncoder().encode(a))
                        try index(a)
                    }
                    if let prefix {
                    var filters = try filters()
                    for i in filters.indices where filters[i].state.rootID == oldRoot.id {
                        filters[i].state.rootID = target.id
                        filters[i].state.folder = DirectoryPaths.join(prefix, filters[i].state.folder ?? "")
                    }
                    try saveFilters(filters)
                    try run("DELETE FROM scan_state WHERE root=?", texts: [oldRoot.id])
                    try run("DELETE FROM roots WHERE id=?", texts: [oldRoot.id])
                    }
                }
                // A fresh traversal discovers the added scope while preserving existing assets.
                try run("DELETE FROM scan_state WHERE root=?", texts: [target.id])
            }
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }

    func scanState(_ root: String) throws -> ScanCheckpoint? {
        lock.lock(); defer { lock.unlock() }
        return try read("SELECT data FROM scan_state WHERE root='\(root.replacingOccurrences(of: "'", with: "''"))'", as: ScanCheckpoint.self).first
    }
    func saveScanState(_ state: ScanCheckpoint) throws {
        lock.lock(); defer { lock.unlock() }
        try run("INSERT OR REPLACE INTO scan_state VALUES(?,?)", texts: [state.rootID], data: JSONEncoder().encode(state))
    }
}

enum DirectoryPaths {
    static func relative(_ path: String, to parent: String) -> String? {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        let parent = URL(fileURLWithPath: parent).standardizedFileURL.path
        if path == parent { return "" }
        let prefix = parent == "/" ? "/" : parent + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }
    static func join(_ prefix: String, _ suffix: String) -> String { [prefix,suffix].filter { !$0.isEmpty }.joined(separator: "/") }
}

struct ScanCheckpoint: Codable {
    var rootID: String
    var path: String
    var pending: [String] = [""]
    var files = 0
    var complete = false
}

enum FilterJoin: String, Codable, CaseIterable { case and = "AND", or = "OR" }
enum FilterField: String, Codable, CaseIterable {
    case art, quality, rating, tag, name, kind, flag, siglip, qwen, fusion
    var title: String {
        switch self {
        case .art: return "AI 艺术分"
        case .quality: return "AI 质量分"
        case .rating: return "星级"
        case .tag: return "标签"
        case .name: return "文件 / 目录 / 标签"
        case .kind: return "素材类型"
        case .flag: return "标记状态"
        case .siglip: return "SigLIP 相似度"
        case .qwen: return "Qwen 相似度"
        case .fusion: return "混合相关度"
        }
    }
    var isEmbedding: Bool { [.siglip, .qwen, .fusion].contains(self) }
    var isNumeric: Bool { [.art, .quality, .rating, .siglip, .qwen, .fusion].contains(self) }
    var comparisons: [FilterComparison] {
        if isNumeric { return [.greaterEqual, .greater, .lessEqual, .less, .equal, .notEqual, .present, .missing] }
        if self == .tag || self == .name { return [.contains, .notContains, .equal, .notEqual, .present, .missing] }
        return [.equal, .notEqual]
    }
}
enum FilterComparison: String, Codable, CaseIterable {
    case greaterEqual, greater, lessEqual, less, equal, notEqual, contains, notContains, present, missing
    var title: String {
        switch self {
        case .greaterEqual: return "≥"
        case .greater: return ">"
        case .lessEqual: return "≤"
        case .less: return "<"
        case .equal: return "="
        case .notEqual: return "≠"
        case .contains: return "包含"
        case .notContains: return "不包含"
        case .present: return "有值"
        case .missing: return "无值"
        }
    }
    var needsValue: Bool { self != .present && self != .missing }
    func compare(_ number: Double?, to target: Double?) -> Bool {
        let number = number.flatMap { $0.isFinite ? $0 : nil }
        if self == .missing { return number == nil }
        if self == .present { return number != nil }
        guard let number, let target, target.isFinite else { return false }
        switch self {
        case .greaterEqual: return number >= target
        case .greater: return number > target
        case .lessEqual: return number <= target
        case .less: return number < target
        case .equal: return number == target
        case .notEqual: return number != target
        default: return false
        }
    }
    func compare(_ values: [String], to target: String) -> Bool {
        if self == .missing { return values.allSatisfy(\.isEmpty) }
        if self == .present { return values.contains { !$0.isEmpty } }
        guard !target.isEmpty else { return false }
        switch self {
        case .equal: return values.contains { $0.localizedCaseInsensitiveCompare(target) == .orderedSame }
        case .notEqual: return !values.contains { $0.localizedCaseInsensitiveCompare(target) == .orderedSame }
        case .contains: return values.contains { $0.localizedCaseInsensitiveContains(target) }
        case .notContains: return !values.contains { $0.localizedCaseInsensitiveContains(target) }
        default: return false
        }
    }
}
struct EmbeddingFilterQuery: Hashable, Codable {
    var backend: String
    var text: String
}
struct FilterScoreContext {
    var art: [String: Double] = [:]
    var quality: [String: Double] = [:]
    // A missing query means pending/failed, not that every photo has no vector.
    var embeddings: [EmbeddingFilterQuery: [String: Double]] = [:]
}
struct FilterRule: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var join: FilterJoin = .and
    var enabled = true
    var field: FilterField = .art
    var comparison: FilterComparison = .greaterEqual
    var value = "4"
    var query = ""
    var embeddingQuery: EmbeddingFilterQuery? {
        guard field.isEmbedding, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return EmbeddingFilterQuery(backend: field.rawValue, text: query.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    var validation: String? {
        if field.isEmbedding && embeddingQuery == nil { return "请输入画面描述" }
        guard comparison.needsValue else { return nil }
        if field.isNumeric {
            guard let number = Double(value), number.isFinite else { return "请输入有效数值" }
        } else if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请输入条件值" }
        return nil
    }
    mutating func select(_ field: FilterField) {
        self.field = field; comparison = field.comparisons[0]
        switch field {
        case .art, .quality: value = "4"
        case .rating: value = "3"
        case .siglip, .qwen: value = "0.2"
        case .fusion: value = "0.5"
        case .kind: value = "photo"
        case .flag: value = "1"
        default: value = ""
        }
    }
    func matches(_ asset: Asset, scores: FilterScoreContext) -> Bool {
        guard validation == nil else { return false }
        switch field {
        case .art: return comparison.compare(scores.art[asset.id], to: Double(value))
        case .quality: return comparison.compare(scores.quality[asset.id], to: Double(value))
        case .rating: return comparison.compare(Double(asset.rating), to: Double(value))
        case .tag: return comparison.compare(asset.tags, to: value)
        case .name: return comparison.compare([asset.name, asset.folder] + asset.tags, to: value)
        case .kind: return comparison.compare([asset.video ? "video" : "photo"], to: value)
        case .flag: return comparison.compare([String(asset.flag)], to: value)
        case .siglip, .qwen, .fusion:
            guard let query = embeddingQuery, let values = scores.embeddings[query] else { return false }
            return comparison.compare(values[asset.id], to: Double(value))
        }
    }
}

struct FilterState: Codable, Equatable {
    var search = ""
    var rating = 0
    var kind = "all"
    var flag = "all"
    var tag = ""
    var rootID: String? = nil
    var folder: String? = nil
    var recursive = true
    var sort = "name"
    // Optional for old saved filters; no catalog migration or destructive write.
    var rules: [FilterRule]? = nil
    var effectiveRules: [FilterRule] {
        var rows = rules ?? []
        // Older fields are retained for compatibility with saved filters and callers.
        if rating > 0 { rows.append(FilterRule(id: "legacy-rating", field: .rating, value: String(rating))) }
        if kind != "all" { rows.append(FilterRule(id: "legacy-kind", field: .kind, comparison: .equal, value: kind)) }
        if flag != "all" { rows.append(FilterRule(id: "legacy-flag", field: .flag, comparison: .equal, value: flag)) }
        if !tag.isEmpty { rows.append(FilterRule(id: "legacy-tag", field: .tag, comparison: .equal, value: tag)) }
        if !search.isEmpty { rows.append(FilterRule(id: "legacy-search", field: .name, comparison: .contains, value: search)) }
        return rows
    }
    mutating func setRules(_ rows: [FilterRule]) {
        rules = rows; search = ""; rating = 0; kind = "all"; flag = "all"; tag = ""
    }
    var hasRules: Bool { effectiveRules.contains(where: \.enabled) }
    var usesAIScores: Bool { effectiveRules.contains { $0.enabled && ($0.field == .art || $0.field == .quality) } }
    var embeddingQueries: [EmbeddingFilterQuery] {
        var seen = Set<EmbeddingFilterQuery>()
        return effectiveRules.filter(\.enabled).compactMap(\.embeddingQuery).filter { seen.insert($0).inserted }
    }
    var scopeIdentity: String {
        String(data: try! JSONEncoder().encode([rootID, folder, recursive ? "recursive" : "direct"]), encoding: .utf8)!
    }
    func hasTag(_ tag: String) -> Bool { effectiveRules.contains { $0.enabled && $0.field == .tag && $0.comparison == .equal && $0.value == tag } }
    mutating func toggleTag(_ tag: String) {
        var rows = effectiveRules
        if let index = rows.firstIndex(where: { $0.enabled && $0.field == .tag && $0.comparison == .equal && $0.value == tag }) { rows.remove(at: index) }
        else { rows.append(FilterRule(field: .tag, comparison: .equal, value: tag)) }
        setRules(rows)
    }
    func matchesScope(_ asset: Asset) -> Bool {
        if let rootID, asset.rootID != rootID { return false }
        if let folder {
            if recursive {
                if !folder.isEmpty && asset.folder != folder && !asset.folder.hasPrefix(folder + "/") { return false }
            } else if asset.folder != folder { return false }
        }
        return true
    }
    func matches(_ asset: Asset, scores: FilterScoreContext = FilterScoreContext()) -> Bool {
        guard matchesScope(asset) else { return false }
        let rows = effectiveRules.filter(\.enabled)
        guard let first = rows.first else { return true }
        // AND binds more tightly than OR: A OR B AND C = A OR (B AND C).
        var group = first.matches(asset, scores: scores)
        var any = false
        for rule in rows.dropFirst() {
            let match = rule.matches(asset, scores: scores)
            if rule.join == .or { any = any || group; group = match }
            else { group = group && match }
        }
        return any || group
    }
}
struct SavedFilter: Codable, Identifiable { var id = UUID().uuidString; var name: String; var state: FilterState }

enum Scanner {
    static let rawExtensions: Set<String> = ["arw", "3fr", "fff", "dng", "cr2", "cr3", "nef", "nrw", "raf", "orf", "rw2", "pef", "srw"]
    static let photos: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"]
    static let videos: Set<String> = ["mp4", "mov", "m4v", "mts", "m2ts", "avi", "mxf"]
    // Case-sensitive stems avoid merging different files on case-sensitive volumes.
    static func assetID(root: String, folder: String, stem: String, video: Bool) -> String { [root, video ? "video" : "photo", folder, stem].joined(separator: "\u{1F}") }
    // A directory is the checkpoint boundary, so RAW + rendered pairs never split across batches.
    static func directory(root: LibraryRoot, relative: String, cancelled: () -> Bool) throws -> ([Asset], [String], Int) {
        let base = URL(fileURLWithPath: root.path)
        let url = relative.isEmpty ? base : base.appendingPathComponent(relative)
        let keys: [URLResourceKey] = [.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey,.isPackageKey,.fileSizeKey,.contentModificationDateKey]
        let entries = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        var groups: [String: Asset] = [:]; var children: [String] = []; var count = 0
        for entry in entries {
            if cancelled() { throw CancellationError() }
            let values = try entry.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true || values.isPackage == true { continue }
            let path = relative.isEmpty ? entry.lastPathComponent : relative + "/" + entry.lastPathComponent
            if values.isDirectory == true { children.append(path); continue }
            let ext = entry.pathExtension.lowercased()
            guard values.isRegularFile == true, photos.contains(ext) || rawExtensions.contains(ext) || videos.contains(ext) else { continue }
            let video = videos.contains(ext); let stem = entry.deletingPathExtension().lastPathComponent
            let id = assetID(root: root.id, folder: relative, stem: video ? entry.lastPathComponent : stem, video: video)
            let file = MediaFile(relativePath: path, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0)
            if groups[id] == nil { groups[id] = Asset(id: id, rootID: root.id, folder: relative, name: stem, video: video, files: [], date: file.modified) }
            groups[id]!.files.append(file); count += 1
        }
        let assets = groups.values.map { item -> Asset in
            var item = item
            item.files.sort {
                let l = $0.isRAW ? 2 : (["heic","heif"].contains($0.ext) ? 0 : 1)
                let r = $1.isRAW ? 2 : (["heic","heif"].contains($1.ext) ? 0 : 1)
                return l == r ? $0.relativePath < $1.relativePath : l < r
            }
            item.date = item.files.map(\.modified).max() ?? 0
            return item
        }
        return (assets, children.sorted(), count)
    }
    static func scan(root: LibraryRoot, progress: (Int) -> Void, cancelled: () -> Bool) throws -> [Asset] {
        let base = URL(fileURLWithPath: root.path).standardizedFileURL
        guard FileManager.default.isReadableFile(atPath: base.path) else { throw CatalogError(message: "目录离线或无法读取：\(root.name)。已有索引已保留。") }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in enumerationError = error; return false }) else { throw CatalogError(message: "无法遍历目录") }
        var groups: [String: Asset] = [:]
        var count = 0
        for case let url as URL in enumerator {
            if cancelled() { throw CancellationError() }
            let ext = url.pathExtension.lowercased()
            guard photos.contains(ext) || rawExtensions.contains(ext) || videos.contains(ext) else { continue }
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let relative = String(url.path.dropFirst(base.path.count + 1))
            let folder = (relative as NSString).deletingLastPathComponent
            let video = videos.contains(ext)
            let stem = url.deletingPathExtension().lastPathComponent
            // Different video files never auto-pair, even when their stems match.
            let id = assetID(root: root.id, folder: folder, stem: video ? url.lastPathComponent : stem, video: video)
            let date = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            let file = MediaFile(relativePath: relative, size: Int64(values.fileSize ?? 0), modified: date)
            if groups[id] == nil { groups[id] = Asset(id: id, rootID: root.id, folder: folder, name: stem, video: video, files: [], date: date) }
            groups[id]!.files.append(file)
            count += 1
            if count % 100 == 0 { progress(count) }
        }
        if let enumerationError { throw enumerationError }
        return groups.values.map { value in
            var asset = value
            asset.files.sort { a, b in
                func rank(_ file: MediaFile) -> Int { file.isRAW ? 2 : (["heic", "heif"].contains(file.ext) ? 0 : 1) }
                return rank(a) == rank(b) ? a.relativePath < b.relativePath : rank(a) < rank(b)
            }
            return asset
        }
    }
}

enum PhotoExportFormat: String, Codable, CaseIterable, Identifiable {
    case jpeg = "JPG", tiff = "TIFF（16 位）"
    var id: String { rawValue }
    var fileExtension: String { self == .jpeg ? "jpg" : "tiff" }
}
struct PhotoExportOptions: Codable {
    var format: PhotoExportFormat = .jpeg
    var quality: Double = 0.9
    var preserveHDR = false
}

enum ExportMode: String, CaseIterable, Identifiable { case edited = "编辑后的照片", originals = "整组原文件", rendered = "直出文件（视频为原片）", raw = "仅 RAW（视频为原片）"; var id: String { rawValue } }
enum Exporter {
    static func files(_ asset: Asset, mode: ExportMode) -> [MediaFile] {
        if asset.video { return asset.files }
        switch mode {
        case .edited: return [asset.preferred]
        case .originals: return asset.files
        case .rendered: return asset.files.filter { !$0.isRAW }
        case .raw: return asset.files.filter(\.isRAW)
        }
    }
    static func destination(base: URL, root: LibraryRoot, file: MediaFile) -> URL {
        base.appendingPathComponent(root.name + "-" + root.id.prefix(6)).appendingPathComponent(file.relativePath)
    }
    static func copy(source: URL, destination: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var target = destination
        var n = 1
        while fm.fileExists(atPath: target.path) {
            target = destination.deletingPathExtension().appendingPathExtension("copy-\(n)." + destination.pathExtension)
            n += 1
        }
        // Copy to a temporary sibling, then rename, so interruption never leaves an apparently complete export.
        let temp = target.deletingLastPathComponent().appendingPathComponent(".photolab-\(UUID().uuidString).partial")
        defer { try? fm.removeItem(at: temp) }
        try fm.copyItem(at: source, to: temp)
        try fm.moveItem(at: temp, to: target)
        return target
    }
}


enum CaptureDates {
    static func readPhoto(_ urls: [URL]) -> Double? {
        for url in urls {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] else { continue }
            for key in [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized] {
                if let text = exif[key] as? String, let date = parse(text) { return date }
            }
        }
        return nil
    }
    static func parse(_ text: String) -> Double? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.isLenient = false
        return formatter.date(from: text)?.timeIntervalSince1970
    }
    static func day(_ timestamp: Double?) -> String {
        guard let timestamp else { return "未知拍摄日期" }
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: timestamp))
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}


enum ExposureFormatting {
    static func string(seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "未知" }
        if seconds >= 1 { return String(format: "%g 秒", seconds) }
        let reciprocal = 1 / seconds
        if reciprocal < 1_000_000_000, abs(reciprocal - reciprocal.rounded()) < 0.001 {
            return "1/\(Int(reciprocal.rounded())) 秒"
        }
        let denominator = 1_000_000
        let numerator = max(1, Int((seconds * Double(denominator)).rounded()))
        var a = numerator, b = denominator
        while b != 0 { let remainder = a % b; a = b; b = remainder }
        return "\(numerator / a)/\(denominator / a) 秒"
    }
}
