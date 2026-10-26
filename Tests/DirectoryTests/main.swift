import Foundation
import CryptoKit

func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CatalogError(message: message) }
}
func scan(_ root: LibraryRoot) throws -> [Asset] {
    var pending = [""]; var result: [Asset] = []
    while let folder = pending.popLast() {
        let (assets, children, _) = try Scanner.directory(root: root, relative: folder, cancelled: { false })
        result += assets; pending += children
    }
    return result
}
func fingerprint(_ asset: Asset) -> String {
    let files = asset.files.map { "\(asset.identityPath($0))|\($0.size)|\($0.modified)" }.joined(separator: "\n")
    return SHA256.hash(data: Data("\(asset.id)|\(files)|\(asset.quarterTurns)|imageio-sdr-srgb-512-rotation-v1".utf8)).description
}
let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("photolab-directory-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: base) }
let media = base.appendingPathComponent("media")
for dir in ["a/sub", "b"] {
    try FileManager.default.createDirectory(at: media.appendingPathComponent(dir), withIntermediateDirectories: true)
    for name in ["A.JPG", "A.ARW", "A.MOV", "A.MP4"] { try Data("original".utf8).write(to: media.appendingPathComponent(dir + "/" + name)) }
}
let catalog = try Catalog(directory: base.appendingPathComponent("catalog"))
try catalog.prepareIndexes()
let children = [LibraryRoot(id: "a", path: media.appendingPathComponent("a").path), LibraryRoot(id: "b", path: media.appendingPathComponent("b").path)]
for root in children {
    try catalog.save(root: root)
    var assets = try scan(root)
    for i in assets.indices { assets[i].rating = 5; assets[i].tags = ["旅行"]; assets[i].rotation = 1; assets[i].captureDate = 100; assets[i].captureDateChecked = true }
    try catalog.save(assets: assets)
}
let before = try catalog.assets()
let fingerprints = Dictionary(uniqueKeysWithValues: before.map { ($0.id, fingerprint($0)) })
try catalog.saveFilters([SavedFilter(name: "a", state: FilterState(rootID: "a", folder: "sub", recursive: false))])
let parent = LibraryRoot(id: "parent", path: media.path)
try catalog.updateDirectory(parent)
var after = try catalog.assets()
try check(try catalog.roots().map(\.id) == ["parent"], "roots were not merged")
try check(after.count == 6 && Set(after.map(\.id)) == Set(before.map(\.id)), "identity lost or duplicates")
for asset in after {
    try check(asset.rating == 5 && asset.tags == ["旅行"] && asset.quarterTurns == 1 && asset.captureDate == 100, "marks lost")
    try check(fingerprints[asset.id] == fingerprint(asset), "AI/cache identity changed")
    for file in asset.files { try check(try String(contentsOf: media.appendingPathComponent(file.relativePath), encoding: .utf8) == "original", "source path broken") }
}
let filter = try catalog.filters()[0].state
try check(filter.rootID == "parent" && filter.folder == "a/sub" && !filter.recursive, "saved filter changed scope")
_ = try catalog.mergeScan(scan(parent))
after = try catalog.assets()
try check(after.count == 6 && after.allSatisfy { $0.rating == 5 && fingerprints[$0.id] == fingerprint($0) }, "rescan duplicated or invalidated assets")
// A second expansion must compose identity paths, including video filename identities.
let grandparent = LibraryRoot(id: "grand", path: base.path)
try catalog.updateDirectory(grandparent)
_ = try catalog.mergeScan(scan(grandparent))
try check(try catalog.assets().count == 6, "nested expansion duplicated")
try check(try catalog.assets().allSatisfy { fingerprints[$0.id] == fingerprint($0) }, "nested identity changed")
try catalog.updateDirectory(grandparent, removing: true)
try check(try catalog.roots().isEmpty && catalog.assets().isEmpty, "removed root still visible")
try check(try catalog.asset(before[0].id)!.rating == 5, "removal deleted annotations")
// Restore just one child from an archived parent, then merge back into that parent.
try catalog.updateDirectory(children[0])
_ = try catalog.mergeScan(scan(children[0]))
try check(try catalog.assets().count == 3 && catalog.assets().allSatisfy { fingerprints[$0.id] == fingerprint($0) }, "archived ancestor restoration duplicated")
try catalog.updateDirectory(grandparent)
try check(try catalog.assets().count == 6, "re-add did not restore")
let reopened = try Catalog(directory: catalog.directory); try reopened.prepareIndexes()
_ = try reopened.mergeScan(scan(grandparent))
try check(try reopened.assets().count == 6 && reopened.assets().allSatisfy { fingerprints[$0.id] == fingerprint($0) }, "reopen lost aliases")
try check(DirectoryPaths.relative("/photos2", to: "/photos") == nil && DirectoryPaths.relative("/photos/a", to: "/") == "photos/a", "path boundaries wrong")
print("PASS: parent merge, nested merge, RAW/video pairing, marks, fingerprints, filter scope, rescan, remove/re-add, reopen")
// Removed/moved subdirectories can be archived without touching source files.
var neighbor = try reopened.assets().first { $0.folder == "media/a/sub" }!
neighbor.id = "neighbor"; neighbor.folder = "media/ab"
try reopened.save(assets: [neighbor])
let archived = try reopened.assets().filter { $0.folder.hasPrefix("media/a/") }
try FileManager.default.moveItem(at: media.appendingPathComponent("a"), to: media.appendingPathComponent("renamed"))
try reopened.removeFolder(rootID: grandparent.id, folder: "media/a")
try check(try reopened.assets().count == 4, "subtree removal affected sibling or missed descendants")
try check(try reopened.assets().contains { $0.id == "neighbor" }, "folder boundary matched sibling prefix")
try check(FileManager.default.fileExists(atPath: media.appendingPathComponent("renamed/sub/A.JPG").path), "removal touched source files")
try reopened.saveMarks([archived[0].id: Marks(archived[0])])
let afterRemoval = try Catalog(directory: catalog.directory)
try check(try afterRemoval.assets().count == 4, "removed subtree reappeared after reopen or late save")
try check(try afterRemoval.asset(archived[0].id)?.rating == 5, "subtree removal lost marks")
try FileManager.default.moveItem(at: media.appendingPathComponent("renamed"), to: media.appendingPathComponent("a"))
try afterRemoval.prepareIndexes()
_ = try afterRemoval.mergeScan(scan(grandparent))
try check(try afterRemoval.assets().count == 7, "rescan did not restore existing subtree")
try check(try afterRemoval.asset(archived[0].id)?.rating == 5, "restored subtree lost marks")
do { try afterRemoval.removeFolder(rootID: grandparent.id, folder: ""); fatalError("empty folder accepted") } catch is CatalogError { }
print("PASS: missing subdirectory removal, descendants, sibling boundaries, source preservation, reopen, late writes and rescan restoration")
