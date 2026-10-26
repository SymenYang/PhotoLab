import Foundation
import CSQLite

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CatalogError(message: message) }
}
func timed<T>(_ operation: () throws -> T) rethrows -> (T,Double) {
    let start = Date(); let value = try operation(); return (value,Date().timeIntervalSince(start))
}
func emit(_ value: [String: Any]) { print(String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!); fflush(stdout) }
let root = FileManager.default.temporaryDirectory.appendingPathComponent("photolab-scale-" + UUID().uuidString)
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
let small = try Catalog(directory:root.appendingPathComponent("small"))
var a = Asset(id:"a", rootID:"r", folder:"", name:"a", video:false,files:[MediaFile(relativePath:"a.jpg",size:10,modified:1)],date:1,rating:5,tags:["旅行"],rotation:1)
try small.save(assets:[a]); try small.prepareIndexes()
try require(FileManager.default.fileExists(atPath:small.directory.appendingPathComponent("catalog-before-scale.sqlite").path),"missing migration backup")
var fresh = a; fresh.rating = 0; fresh.tags = []; fresh.rotation = nil; fresh.files[0].size = 20
let merged = try small.mergeScan([fresh])
try require(merged[0].rating == 5 && merged[0].tags == ["旅行"] && merged[0].quarterTurns == 1,"scan overwrote marks")
a.rating = 2; try small.saveMarks([a.id:Marks(a)])
let persisted = try small.asset("a")!
try require(persisted.files[0].size == 20 && persisted.rating == 2,"late marking overwrote scan metadata")
a.captureDate = 10; a.captureDateChecked = true; try small.saveDates([a])
try require(try small.asset("a")!.captureDate == nil,"stale date persisted")
var checkpoint = ScanCheckpoint(rootID:"r",path:"/unavailable");checkpoint.pending = ["sub"]
try small.saveScanState(checkpoint)
let reopened = try Catalog(directory:small.directory)
try require(try reopened.scanState("r")!.pending == ["sub"],"checkpoint lost on reopen")
let scanRoot = root.appendingPathComponent("media")
try FileManager.default.createDirectory(at:scanRoot.appendingPathComponent("child"),withIntermediateDirectories:true)
for file in ["A.JPG","A.ARW","A.MOV","A.MP4","ignore.txt"] { try Data("test".utf8).write(to:scanRoot.appendingPathComponent(file)) }
let library = LibraryRoot(id:"scan",path:scanRoot.path)
let (scanned, children, count) = try Scanner.directory(root:library,relative:"",cancelled:{false})
try require(scanned.count == 3 && count == 4 && children == ["child"],"scan pairing or directory boundary")
try require(scanned.first(where:{$0.name == "A" && !$0.video})!.files.count == 2,"raw pair split")
do { _ = try Scanner.directory(root:library,relative:"",cancelled:{true}); fatalError("cancellation ignored") } catch is CancellationError {}
let cache = PreviewCache(root:root.appendingPathComponent("cache"),budget:150)
for (folder,name,kind) in [("Thumbnails","t.jpg","thumbnail"),("Originals","o.jpg","original")] {
    let url = cache.root.appendingPathComponent(folder+"/"+name); try Data(repeating:1,count:100).write(to:url); cache.record(url,kind:kind)
}
cache.trim()
try require(cache.usedBytes <= 150,"cache over budget")
try require(FileManager.default.fileExists(atPath:cache.root.appendingPathComponent("Thumbnails/t.jpg").path),"thumbnail was not protected")
cache.trim(clear:true);try require(cache.usedBytes == 0,"cache clear failed")
try require(try small.asset("a")!.rating == 2,"cache cleaning touched catalog")
emit(["correctness":"PASS","temporaryDirectory":root.path])

for n in [20_000,100_000,200_000] {
    let db = try Catalog(directory:root.appendingPathComponent("db-\(n)"));try db.prepareIndexes()
    let library = LibraryRoot(id:"scale",path:root.appendingPathComponent("synthetic-offline").path)
    try db.save(root:library)
    let assets = (0..<n).map { j -> Asset in
        let i = (j * 104729) % n
        let folder = "trip/\(i / 200)";let stem = "Photo\(i)"
        return Asset(id:"asset-\(i)",rootID:library.id,folder:folder,name:stem,video:i % 20 == 0,
                     files:[MediaFile(relativePath:folder+"/"+stem+".JPG",size:10_000_000,modified:Double(i)),MediaFile(relativePath:folder+"/"+stem+".ARW",size:40_000_000,modified:Double(i))],date:Double(i),rating:i % 6,tags:i % 3 == 0 ? ["旅行"] : [],captureDate:Double(i),captureDateChecked:true)
    }
    let (_,save) = try timed { for start in stride(from:0,to:n,by:500) { try db.save(assets:Array(assets[start..<min(n,start+500)])) } }
    let (loaded,load) = try timed { try db.assets() }
    try require(loaded.count == n,"wrong loaded count")
    let (sorted,sort) = timed { LibraryQuery.run(loaded,filter:FilterState(),dates:false,semantic:nil) }
    try require(sorted.count == n, "sort lost items")
    var filter = FilterState(); filter.rating = 3;filter.tag = "旅行";filter.folder = "trip/10"
    let (matched,filtered) = timed { LibraryQuery.run(loaded,filter:filter,dates:false,semantic:nil) }
    try require(!matched.isEmpty && matched.allSatisfy(filter.matches),"filter scope leaked")
    let (_,summary) = timed { LibrarySummary.make(loaded) }
    let (_,cancel) = timed { LibraryQuery.run(loaded,filter:FilterState(),dates:false,semantic:nil,cancelled:{true}) }
    var changed = loaded[0];changed.rating = 5
    let (_,mark) = try timed { try db.saveMarks([changed.id:Marks(changed)]) }
    emit(["assets":n,"writeSeconds":save,"loadSeconds":load,"sortSeconds":sort,"filterSeconds":filtered,"summarySeconds":summary,"cancelSeconds":cancel,"markSeconds":mark,"directory":db.directory.path])
}
