import Foundation
import AppKit

@main struct ScaleIntegration {
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !ready() {
            if Date() > deadline { throw CatalogError(message:"integration timeout") }
            try await Task.sleep(for:.milliseconds(10))
        }
    }
    @MainActor static func main() async throws {
        let savedGrouping = UserDefaults.standard.object(forKey: "groupByCaptureDate")
        UserDefaults.standard.set(false, forKey: "groupByCaptureDate")
        defer {
            if let savedGrouping { UserDefaults.standard.set(savedGrouping, forKey: "groupByCaptureDate") }
            else { UserDefaults.standard.removeObject(forKey: "groupByCaptureDate") }
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("photolab-integration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        let media = temp.appendingPathComponent("media")
        for d in 0..<20 {
            let folder = media.appendingPathComponent("trip\(d)");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            for i in 0..<10 { for ext in ["JPG","ARW"] { try Data([1]).write(to:folder.appendingPathComponent("A\(i).\(ext)")) } }
        }
        let root = LibraryRoot(id:"integration",path:media.path)
        let catalog = try Catalog(directory:temp.appendingPathComponent("catalog"));try catalog.prepareIndexes();try catalog.save(root:root)
        let (first,_,_) = try Scanner.directory(root:root,relative:"trip0",cancelled:{false}); _ = try catalog.mergeScan(first)
        var checkpoint = ScanCheckpoint(rootID:root.id,path:root.path);checkpoint.pending = (1..<20).map { "trip\($0)" };checkpoint.files = 20
        try catalog.saveScanState(checkpoint)
        // The completed directory may be offline on resume; it must not be reread or marked deleted.
        try FileManager.default.moveItem(at:media.appendingPathComponent("trip0"),to:temp.appendingPathComponent("completed-offline"))
        let model = LibraryModel(catalog:catalog)
        try await wait { !model.loading && !model.querying }
        model.scan(root)
        model.mark(assetID:first[0].id,rating:5,addTags:["during scan"])
        try await wait { !model.scanning && model.pendingWrites == 0 && !model.querying }
        guard model.assets.count == 200, model.assets.allSatisfy({ !$0.missing }),
              let marked = try catalog.asset(first[0].id), marked.rating == 5, marked.tags == ["during scan"],
              try catalog.scanState(root.id)?.complete == true else { throw CatalogError(message:"resume or concurrent mark failed") }
        guard !model.indexingDates, model.assets.allSatisfy({ $0.captureDateChecked != true }) else {
            throw CatalogError(message: "date indexing ran while grouping was disabled")
        }
        model.groupByCaptureDate = true
        model.groupByCaptureDate = false
        model.groupByCaptureDate = true
        try await wait { !model.indexingDates && model.pendingWrites == 0 && !model.querying }
        guard model.assets.filter({ $0.captureDateChecked == true }).count == 190,
              model.gridSections.reduce(0, { $0 + $1.1.count }) == model.gridAssets.count,
              try catalog.assets().filter({ $0.captureDateChecked == true }).count == 190 else {
            throw CatalogError(message: "date indexing restart, offline retry, persistence or grid grouping failed")
        }
        model.groupByCaptureDate = false
        try await wait { !model.querying }
        guard model.gridSections.count == 1, model.gridSections[0].0.isEmpty else {
            throw CatalogError(message: "ungrouped grid cache was stale")
        }
        model.undo(); try await wait { model.pendingWrites == 0 && !model.querying }
        guard try catalog.asset(first[0].id)?.rating == 0 else { throw CatalogError(message:"asynchronous undo failed") }
        model.saveFailed = true; model.retrySaving()
        try await wait { model.pendingWrites == 0 }
        guard !model.saveFailed else { throw CatalogError(message:"retry did not recover saved state") }
        model.filter.search = "no-such-photo"; model.filter.search = "A1"
        try await wait { !model.querying }
        guard model.filtered.count == 20 else { throw CatalogError(message:"stale filter result published") }
        var offline = root;offline.path = temp.appendingPathComponent("not-mounted").path
        model.scan(offline)
        try await wait { !model.scanning }
        guard model.assets.count == 200 && model.assets.allSatisfy({ !$0.missing }), try catalog.scanState(root.id)?.complete == true else { throw CatalogError(message:"offline scan changed catalog") }
        model.error = nil
        let ids = Set(model.assets.map(\.id))
        model.changeDirectory(root, removing: true)
        try await wait { model.pendingWrites == 0 && !model.querying }
        guard model.assets.isEmpty && model.roots.isEmpty else { throw CatalogError(message:"removed directory still in model") }
        model.addRoot(media)
        try await wait { model.pendingWrites == 0 && !model.scanning && !model.querying }
        guard Set(model.assets.map(\.id)) == ids && model.roots.first?.id == root.id else { throw CatalogError(message:"re-add failed to recover identities") }
        let parent = LibraryRoot(id:"expanded",path:temp.path)
        model.changeDirectory(parent, removing: false)
        try await wait { model.pendingWrites == 0 && !model.scanning && !model.querying }
        guard model.roots.map(\.id) == [parent.id], Set(model.assets.map(\.id)).isSuperset(of:ids), model.assets.count == 210 else { throw CatalogError(message:"parent scan duplicated existing assets") }
        print("PASS remove/re-add and parent merge UI state; resumed directory scan, concurrent marks, background undo, latest query wins, offline preservation")
    }
}
