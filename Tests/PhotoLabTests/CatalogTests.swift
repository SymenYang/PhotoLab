import Foundation
import ImageIO
import CoreGraphics

final class CatalogTests {
    var directory: URL!
    func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoLabTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    func file(_ path: String, text: String = "fixture") throws {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func testPairsRAWWithRenderedButSeparatesFoldersAndVideos() throws {
        for path in ["day1/A.ARW", "day1/A.JPG", "day1/A.MP4", "day2/A.ARW", "day2/A.HEIC", "day2/ignore.txt"] { try file(path) }
        let assets = try Scanner.scan(root: LibraryRoot(id: "root", path: directory.path), progress: { _ in }, cancelled: { false })
        XCTAssertEqual(assets.count, 3)
        XCTAssertEqual(assets.filter(\.video).count, 1)
        XCTAssertEqual(assets.filter { !$0.video }.map { $0.files.count }, [2, 2])
        XCTAssertTrue(assets.filter { !$0.video }.allSatisfy { !$0.preferred.isRAW })
    }
    func testDatabaseRoundTripAndMarksPersistence() throws {
        let root = LibraryRoot(id: "root", path: directory.path)
        var asset = Asset(id: "asset", rootID: root.id, folder: "", name: "B", video: false, files: [MediaFile(relativePath: "B.3FR", size: 300, modified: 0)], date: 0)
        asset.rotation = 3; asset.captureDate = 123456; asset.captureDateChecked = true
        asset.rating = 4; asset.flag = 1; asset.tags = ["旅行", "Bob's shot"]
        do { let catalog = try Catalog(directory: directory.appendingPathComponent("db")); try catalog.save(root: root); try catalog.save(assets: [asset]) }
        let reopened = try Catalog(directory: directory.appendingPathComponent("db"))
        XCTAssertEqual(try reopened.assets(), [asset])
        XCTAssertEqual(try reopened.roots(), [root])
        asset.rating = 2; try reopened.save(assets: [asset])
        XCTAssertEqual(try reopened.assets().count, 1)
        XCTAssertEqual(try reopened.assets()[0].rating, 2)
    }
    func testFilterRespectsFolderBoundariesAndMedia() {
        let asset = Asset(id: "a", rootID: "r", folder: "trip/one", name: "sea", video: true, files: [], date: 0, rating: 4, flag: 1, tags: ["海边"])
        var filter = FilterState(); filter.folder = "trip"; filter.rating = 3; filter.kind = "video"; filter.tag = "海边"
        XCTAssertTrue(filter.matches(asset))
        filter.recursive = false; XCTAssertFalse(filter.matches(asset))
        filter.recursive = true; filter.folder = "tri"; XCTAssertFalse(filter.matches(asset))
        filter.folder = nil; filter.kind = "photo"; XCTAssertFalse(filter.matches(asset))
    }
    func testExportPreservesSourceAndNeverOverwritesExistingDestination() throws {
        try file("source.MP4", text: "original bytes")
        try file("export/source.MP4", text: "existing bytes")
        let source = directory.appendingPathComponent("source.MP4")
        let originalTarget = directory.appendingPathComponent("export/source.MP4")
        let target = try Exporter.copy(source: source, destination: originalTarget)
        XCTAssertNotEqual(target, originalTarget)
        XCTAssertEqual(try Data(contentsOf: source), Data("original bytes".utf8))
        XCTAssertEqual(try Data(contentsOf: target), try Data(contentsOf: source))
        XCTAssertEqual(try Data(contentsOf: originalTarget), Data("existing bytes".utf8))
    }
    func testExportModeIncludesOriginalVideoAndSelectedPhotoVariants() {
        let files = [MediaFile(relativePath: "a.ARW", size: 1, modified: 0), MediaFile(relativePath: "a.JPG", size: 1, modified: 0)]
        var asset = Asset(id: "a", rootID: "r", folder: "", name: "a", video: false, files: files, date: 0)
        XCTAssertEqual(Exporter.files(asset, mode: .raw).map(\.ext), ["arw"])
        XCTAssertEqual(Exporter.files(asset, mode: .rendered).map(\.ext), ["jpg"])
        asset.video = true; asset.files = [MediaFile(relativePath: "a.MP4", size: 1, modified: 0)]
        for mode in ExportMode.allCases { XCTAssertEqual(Exporter.files(asset, mode: mode), asset.files) }
    }
    func testLegacyCatalogAndRotationRescan() throws {
        let legacy = #"{"id":"a","rootID":"r","folder":"","name":"a","video":false,"files":[],"date":0,"rating":0,"flag":0,"tags":[],"missing":false}"#
        var asset = try JSONDecoder().decode(Asset.self, from: Data(legacy.utf8))
        XCTAssertEqual(asset.quarterTurns, 0)
        XCTAssertEqual(asset.captureDate, nil)
        asset.rotation = -1
        var rescanned = try JSONDecoder().decode(Asset.self, from: Data(legacy.utf8))
        Marks(asset).apply(to: &rescanned)
        XCTAssertEqual(rescanned.quarterTurns, 3)
        rescanned.rotation = rescanned.quarterTurns + 1
        XCTAssertEqual(rescanned.quarterTurns, 0)
    }
    func testCaptureDateUsesEXIFAndUnknownDoesNotUseFileTime() throws {
        let url = directory.appendingPathComponent("dated.jpg")
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:06 23:59:00"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let date = CaptureDates.readPhoto([url])
        XCTAssertEqual(CaptureDates.day(date), "2024-05-06")
        XCTAssertEqual(CaptureDates.day(nil), "未知拍摄日期")
        XCTAssertEqual(CaptureDates.parse("invalid"), nil)
        try file("no-exif.jpg")
        XCTAssertEqual(CaptureDates.readPhoto([directory.appendingPathComponent("no-exif.jpg")]), nil)
    }
    func testCancelledScanDoesNotReturnPartialResult() throws {
        try file("a.JPG")
        XCTAssertThrowsError(try Scanner.scan(root: LibraryRoot(id: "r", path: directory.path), progress: { _ in }, cancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
    }
}

func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { let left = try a(); let right = try b(); if left != right { fatalError("Expected equality: \(left) != \(right)", file: file, line: line) } } catch { fatalError("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertNotEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) { if a == b { fatalError("Expected inequality", file: file, line: line) } }
func XCTAssertTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) { if !value { fatalError("Expected true", file: file, line: line) } }
func XCTAssertFalse(_ value: Bool, file: StaticString = #file, line: UInt = #line) { if value { fatalError("Expected false", file: file, line: line) } }
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ handler: (Error) -> Void) { do { _ = try expression(); fatalError("Expected error") } catch { handler(error) } }
@main struct TestRunner {
    static func main() throws {
        let tests: [(String, (CatalogTests) throws -> Void)] = [
            ("RAW pairing / folders / media separation", { try $0.testPairsRAWWithRenderedButSeparatesFoldersAndVideos() }),
            ("SQLite round trip / marks persistence", { try $0.testDatabaseRoundTripAndMarksPersistence() }),
            ("Filter boundaries and media", { $0.testFilterRespectsFolderBoundariesAndMedia() }),
            ("Export source preservation and collision", { try $0.testExportPreservesSourceAndNeverOverwritesExistingDestination() }),
            ("Export mode semantics", { $0.testExportModeIncludesOriginalVideoAndSelectedPhotoVariants() }),
            ("Legacy catalog / rotation rescan", { try $0.testLegacyCatalogAndRotationRescan() }),
            ("EXIF capture dates / unknown dates", { try $0.testCaptureDateUsesEXIFAndUnknownDoesNotUseFileTime() }),
            ("Cancelled scan", { try $0.testCancelledScanDoesNotReturnPartialResult() })
        ]
        for (name, run) in tests {
            let suite = CatalogTests(); try suite.setUpWithError()
            do { try run(suite); try suite.tearDownWithError(); print("PASS \(name)") }
            catch { try? suite.tearDownWithError(); throw error }
        }
        print("All \(tests.count) tests passed")
    }
}
