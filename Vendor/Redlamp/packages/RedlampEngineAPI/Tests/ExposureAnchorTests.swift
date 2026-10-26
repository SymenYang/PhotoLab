import Foundation
import Testing
@testable import RedlampEngineAPI

/// Redlamp Reproduction's exposure anchor (CAM-28): each photo's own camera's, written when the
/// look arrives, never copied from another photo, and kept as a newer Redlamp wrote it.
struct ExposureAnchorTests {
    static let canon = ExposureAnchor(stops: 0.94, source: .target, camera: "Canon EOS R5")
    static let sony = ExposureAnchor.typical(for: "Sony ILCE-7RM5")

    static func reproduction(_ anchor: ExposureAnchor? = nil) -> EditRecipe {
        var recipe = EditRecipe()
        recipe.baseLook = BuiltInBaseLook.reproduction.reference
        recipe.exposureAnchor = anchor
        return recipe
    }

    @Test func `the look's arrival writes the photo's anchor and keeps the one it has`() {
        #expect(Self.reproduction().anchored(Self.canon).exposureAnchor == Self.canon)
        var recalibrated = Self.canon
        recalibrated.stops = 1.1
        #expect(Self.reproduction(Self.canon).anchored(recalibrated).exposureAnchor == Self.canon)
        #expect(Self.reproduction(Self.sony).anchored(Self.canon).exposureAnchor == Self.canon, "another camera's goes")
    }

    @Test func `before process 16 other looks and photos that aren't raw have none`() {
        var color = Self.reproduction(Self.canon)
        color.baseLook = BuiltInBaseLook.color.reference
        color.processVersion = 15
        #expect(color.anchored(Self.canon).exposureAnchor == nil)
        #expect(Self.reproduction(Self.canon).anchored(nil).exposureAnchor == nil)
    }

    @Test func `from process 16 every look keeps the photo's anchor, and it leaves the edit pristine`() {
        var color = EditRecipe()
        #expect(color.processVersion >= 16)
        color = color.anchored(Self.canon)
        #expect(color.exposureAnchor == Self.canon && color.isPristine)
        color.processVersion = 15
        #expect(!color.isPristine, "an older edit's anchor came from Redlamp Reproduction")
        #expect(color.anchored(Self.canon).exposureAnchor == nil)
    }

    @Test func `an estimate carries the file's BaselineExposure, a calibration doesn't`() {
        let estimate = ExposureAnchor(stops: 1.2, source: .estimated, camera: "Leica M11")
        #expect(estimate.stops(baseline: 0.5) == 1.7)
        #expect(Self.canon.stops(baseline: 0.5) == Self.canon.stops)
        #expect(Self.sony.stops(baseline: 0.5) == Self.sony.stops)
    }

    @Test func `the table gives a camera its own value, else its maker and format's, else its maker's`() {
        let table = ExposureAnchorTable(
            cameras: ["Canon EOS R5": 0.8], families: ["Canon|CR3": 0.7, "Canon|CR2": 0.2], makes: ["Canon": 0.3],
        )
        func stops(_ model: String, _ format: String, make: String = "Canon") -> Double {
            table.anchor(make: make, model: model, format: format).stops - ExposureAnchor.typicalStops
        }
        #expect(abs(stops("EOS R5", "CR3") - 0.8) < 1e-9)
        #expect(abs(stops("EOS R8", "cr3") - 0.7) < 1e-9)
        #expect(abs(stops("EOS D30", "CRW") - 0.2) < 1e-9, "CRW shares CR2's family")
        #expect(abs(stops("PowerShot", "DNG") - 0.3) < 1e-9)
        #expect(abs(stops("X100V", "RAF", make: "Fujifilm")) < 1e-9, "an unknown maker gets the typical anchor")
        let anchor = table.anchor(make: "Canon", model: "EOS R5", format: "CR3")
        #expect(anchor.source == .estimated && anchor.camera == "Canon EOS R5")
    }

    @Test func `the bundled table has the cameras the bench measured`() {
        let table = ExposureAnchorTable.bundled
        #expect(table.cameras.count > 500 && table.families["Canon|CR3"] != nil && table.makes["Sony"] != nil)
    }

    @Test func `pasting the Base Look never copies the anchor`() {
        let pasted = EditRecipe().pasting(Self.reproduction(Self.canon), SettingsSelection(items: ["look.baseLook"]))
        #expect(pasted.baseLook.isReproduction)
        #expect(pasted.exposureAnchor == nil)
        #expect(pasted.anchored(Self.sony).exposureAnchor == Self.sony)
    }

    @Test func `it round-trips, keeping what a newer Redlamp wrote in it`() throws {
        let json = #"""
        {"baseLook":{"id":"redlamp/base/reproduction"},
         "exposureAnchor":{"stops":0.94,"source":"table","camera":"Canon EOS R5","iso":100}}
        """#
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
        #expect(recipe.baseLook.isReproduction)
        #expect(recipe.exposureAnchor?.stops == 0.94 && recipe.exposureAnchor?.camera == "Canon EOS R5")
        let written = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(recipe))
        guard case let .object(fields) = written, case let .object(anchor)? = fields["exposureAnchor"] else {
            Issue.record("no exposureAnchor in \(written)")
            return
        }
        #expect(anchor["source"] == .string("table"))
        #expect(anchor["iso"] == .number(100))
        #expect(try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe)) == recipe)
    }

    @Test func `an edit without one writes none and stays pristine`() throws {
        let written = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(EditRecipe()))
        guard case let .object(fields) = written else { return }
        #expect(fields["exposureAnchor"] == nil)
        var anchored = EditRecipe()
        anchored.processVersion = 15
        anchored.exposureAnchor = Self.canon
        #expect(EditRecipe().isPristine && !anchored.isPristine)
    }
}
