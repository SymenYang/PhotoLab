import Foundation
import CSQLite

// Owns only regenerable data. The catalog and AI vectors live outside this directory.
final class PreviewCache: @unchecked Sendable {
    static let shared = PreviewCache()
    let root: URL
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let accessQueue = DispatchQueue(label: "photolab.cache-access", qos: .utility)
    private let testBudget: Int64?
    private var totalCacheBytes: Int64 = 0
    private var writes = 0
    private var active: [String: Int] = [:]
    static let reserveBytes: Int64 = 20_000_000_000
    var budgetBytes: Int64 {
        if let testBudget { return testBudget }
        let gb = UserDefaults.standard.integer(forKey: "previewCacheGB")
        return Int64(gb > 0 ? gb : 200) * 1_000_000_000
    }
    init(root: URL? = nil, budget: Int64? = nil) {
        self.testBudget = budget
        self.root = root ?? ProcessInfo.processInfo.environment["PHOTOLAB_CACHE_DIR"].map { URL(fileURLWithPath:$0) } ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("PhotoLab")
        for folder in ["Thumbnails", "Originals", "Previews", "Analysis", "Images"] { try? FileManager.default.createDirectory(at: self.root.appendingPathComponent(folder), withIntermediateDirectories: true) }
        sqlite3_open(self.root.appendingPathComponent("cache.sqlite").path, &db)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS entries(path TEXT PRIMARY KEY,kind TEXT,size INTEGER,access REAL); CREATE INDEX IF NOT EXISTS cache_lru ON entries(kind,access);", nil,nil,nil)
        statement("SELECT COALESCE(SUM(size),0) FROM entries") { if sqlite3_step($0) == SQLITE_ROW { totalCacheBytes = sqlite3_column_int64($0,0) } }
    }
    deinit { sqlite3_close(db) }
    private func statement(_ sql: String, values: [String] = [], body: (OpaquePointer?) -> Void = { _ in }) {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&s,nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(s) }
        let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self)
        for (i,v) in values.enumerated() { sqlite3_bind_text(s,Int32(i+1),v,-1,transient) }
        body(s)
    }
    func record(_ url: URL, kind: String) {
        lock.lock(); defer { lock.unlock() }
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return }
        let relative = String(url.path.dropFirst(root.path.count + 1))
        var previous: Int64 = 0
        statement("SELECT size FROM entries WHERE path=?",values:[relative]) { if sqlite3_step($0) == SQLITE_ROW { previous = sqlite3_column_int64($0,0) } }
        totalCacheBytes += Int64(size) - previous
        statement("INSERT INTO entries VALUES(?,?,?,?) ON CONFLICT(path) DO UPDATE SET size=excluded.size,access=excluded.access", values: [relative,kind,String(size),String(Date().timeIntervalSince1970)]) { _ = sqlite3_step($0) }
        writes += 1
        if writes % 32 == 0 { trim() }
    }
    func touch(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        let relative = String(url.path.dropFirst(root.path.count + 1)); let now = Date().timeIntervalSince1970
        statement("UPDATE entries SET access=? WHERE path=? AND access<?", values: [String(now),relative,String(now-3600)]) { _ = sqlite3_step($0) }
    }
    var usedBytes: Int64 { lock.lock(); defer { lock.unlock() }; return totalCacheBytes }
    func usage() -> String {
        lock.lock(); defer { lock.unlock() }; var lines: [String] = []
        statement("SELECT kind,SUM(size) FROM entries GROUP BY kind") { s in
            while sqlite3_step(s) == SQLITE_ROW {
                let kind = String(cString: sqlite3_column_text(s,0)); let size = sqlite3_column_int64(s,1)
                let name = kind == "thumbnail" ? "缩略图" : kind == "original" ? "近期原片" : kind == "analysis" ? "AI 分析预览" : "浏览预览"
                lines.append("\(name)：\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
            }
        }
        return lines.joined(separator: "\n") + "\n上限 \(budgetBytes / 1_000_000_000) GB · SSD 保留至少 20 GB 可用空间"
    }
    func migrateAndTrim() {
        lock.lock()
        var known = Set<String>()
        statement("SELECT path FROM entries") { s in while sqlite3_step(s) == SQLITE_ROW { known.insert(String(cString:sqlite3_column_text(s,0))) } }
        lock.unlock()
        let originals = root.appendingPathComponent("Originals")
        for url in (try? FileManager.default.contentsOfDirectory(at:originals,includingPropertiesForKeys:nil)) ?? [] where url.lastPathComponent.hasPrefix(".") && url.pathExtension == "partial" {
            lock.lock()
            if active[url.path, default:0] == 0 { try? FileManager.default.removeItem(at:url) }
            lock.unlock()
        }
        for folder in ["Thumbnails","Originals","Previews","Analysis","Images"] {
            let urls = (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(folder), includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
            for url in urls where !known.contains(folder + "/" + url.lastPathComponent) {
                record(url,kind:folder == "Thumbnails" ? "thumbnail" : folder == "Originals" ? "original" : folder == "Analysis" ? "analysis" : "preview")
            }
        }
        trim()
    }
    func trim(clear: Bool = false, requiredBytes: Int64 = 0) {
        lock.lock(); defer { lock.unlock() }
        var total = usedBytes
        var free = ((try? FileManager.default.attributesOfFileSystem(forPath: root.path)[.systemFreeSize]) as? NSNumber)?.int64Value ?? Int64.max
        let target = clear ? 0 : max(0, budgetBytes - requiredBytes)
        guard clear || total > target || free < Self.reserveBytes else { return }
        var candidates: [(String,Int64)] = []
        // Preserve full-library thumbnails until other cache classes have been evicted.
        statement("SELECT path,size FROM entries ORDER BY (kind='thumbnail'),access") { s in
            while sqlite3_step(s) == SQLITE_ROW { candidates.append((String(cString:sqlite3_column_text(s,0)),sqlite3_column_int64(s,1))) }
        }
        for (path,size) in candidates {
            if !clear && total <= target && free >= Self.reserveBytes { break }
            let url = root.appendingPathComponent(path)
            if active[url.path, default: 0] > 0 { continue }
            do {
                if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url); free += size }
                statement("DELETE FROM entries WHERE path=?", values:[path]) { _ = sqlite3_step($0) }
                total -= size; totalCacheBytes -= size
            } catch { continue }
        }
    }
    // Copies are small and protected against concurrent cache eviction. A failed
    // cache write never prevents indexing; the caller owns its temporary input.
    func copyAnalysis(key: String, to destination: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let cached = root.appendingPathComponent("Analysis/\(key).jpg")
        do { try FileManager.default.copyItem(at: cached, to: destination); touch(cached); return true }
        catch { return false }
    }
    func storeAnalysis(key: String, from source: URL) {
        lock.lock(); defer { lock.unlock() }
        let cached = root.appendingPathComponent("Analysis/\(key).jpg")
        guard let data = try? Data(contentsOf: source) else { return }
        trim(requiredBytes: Int64(data.count))
        let free = ((try? FileManager.default.attributesOfFileSystem(forPath: root.path)[.systemFreeSize]) as? NSNumber)?.int64Value ?? 0
        guard free - Int64(data.count) >= Self.reserveBytes, usedBytes + Int64(data.count) <= budgetBytes else { return }
        do { try data.write(to: cached, options: .atomic); record(cached, kind: "analysis") } catch { }
    }
    func imageData(key: String) -> Data? {
        // Atomic replacement means a reader sees a complete file or a cache miss.
        // Eviction and index maintenance must never hold up a cache hit.
        let url = root.appendingPathComponent("Images/" + key + ".jpg", isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { return nil }
        accessQueue.async { self.touch(url) }
        return data
    }
    func storeImage(_ data: Data, key: String, dimension: Int) {
        lock.lock(); defer { lock.unlock() }
        trim(requiredBytes: Int64(data.count))
        let free = ((try? FileManager.default.attributesOfFileSystem(forPath: root.path)[.systemFreeSize]) as? NSNumber)?.int64Value ?? 0
        guard free - Int64(data.count) >= Self.reserveBytes, usedBytes + Int64(data.count) <= budgetBytes else { return }
        let url = root.appendingPathComponent("Images/" + key + ".jpg", isDirectory: false)
        do { try data.write(to: url, options: .atomic); record(url, kind: dimension <= 1440 ? "thumbnail" : "preview") } catch { }
    }
    private func pin(_ url: URL) -> URL {
        lock.lock(); defer { lock.unlock() }; active[url.path, default: 0] += 1; return url
    }
    func release(_ url: URL) {
        lock.lock(); defer { lock.unlock() }; if let count = active[url.path] { active[url.path] = count > 1 ? count - 1 : nil }
    }
    // Local volumes (including USB disks) already hold the original; copying
    // them into the internal cache wastes space. Resolve symlinks before probing.
    static func isLocalOriginal(_ source: URL) -> Bool {
        (try? source.resolvingSymlinksInPath().resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == true
    }
    func original(_ source: URL, key: String) -> URL {
        if Self.isLocalOriginal(source), FileManager.default.isReadableFile(atPath: source.path) { return source }
        let destination = root.appendingPathComponent("Originals/" + key + "." + source.pathExtension)
        if FileManager.default.fileExists(atPath: destination.path) { touch(destination); return pin(destination) }
        guard let size = (try? source.resourceValues(forKeys:[.fileSizeKey]))?.fileSize, Int64(size) < budgetBytes / 4 else { return source }
        trim(requiredBytes: Int64(size))
        let free = ((try? FileManager.default.attributesOfFileSystem(forPath:root.path)[.systemFreeSize]) as? NSNumber)?.int64Value ?? 0
        guard free - Int64(size) >= Self.reserveBytes, usedBytes + Int64(size) <= budgetBytes else { return source }
        let temporary = root.appendingPathComponent("Originals/." + UUID().uuidString + ".partial")
        _ = pin(temporary)
        defer { release(temporary); try? FileManager.default.removeItem(at:temporary) }
        do {
            try FileManager.default.copyItem(at:source,to:temporary)
            try FileManager.default.moveItem(at:temporary,to:destination)
            record(destination,kind:"original"); return pin(destination)
        } catch { return source }
    }
}
