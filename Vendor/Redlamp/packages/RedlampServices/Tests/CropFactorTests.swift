import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampServices

/// What a raw tells lens profiles about its frame and lens beside its make, model and lens name
/// (LNS-14): its crop factor, LibRaw's canonical name for the camera, and the lens's number and
/// focal lengths.
struct CropFactorTests {
    @Test func `a stated 35 mm-equivalent focal length rounds to the format LibRaw knows, or follows a crop mode`() {
        // A Fujifilm X-T3 at 35 mm states 53 mm: APS-C's 1.53, which 53 mm rounds from.
        #expect(CropFactor.of(focalLength: 35, equivalent: 53, format: 1.53) { nil } == 1.53)
        // A full-frame Z5 II in its DX crop mode at 24 mm states 36 mm.
        #expect(CropFactor.of(focalLength: 24, equivalent: 36, format: 1) { nil } == 1.5)
        // A phone has no format LibRaw knows: the stated factor stands.
        #expect(CropFactor.of(focalLength: 4.2, equivalent: 26, format: nil) { nil } == 26 / 4.2)
    }

    @Test func `without one, a focal plane resolution that makes the frame full frame overrules LibRaw`() {
        // LibRaw takes a Canon body it doesn't know (the EOS R6 Mark III) for APS-C.
        #expect(CropFactor.of(focalLength: 50, equivalent: 0, format: 1.61) { 1.002 } == 1)
        // The EOS 5D Mark IV's states 29.9 mm across, which is no format: LibRaw's full frame stands.
        #expect(CropFactor.of(focalLength: 40, equivalent: 0, format: 1) { 1.207 } == 1)
        #expect(CropFactor.of(focalLength: 25, equivalent: 0, format: 2) { nil } == 2)
        #expect(CropFactor.of(focalLength: 0, equivalent: 0, format: nil) { nil } == nil)
    }

    @Test func `each format LibRaw names has its usual crop factor`() {
        #expect(CropFactor.nominal(format: 1, make: "Canon") == 1.61)
        #expect(CropFactor.nominal(format: 1, make: "Nikon") == 1.53)
        #expect(CropFactor.nominal(format: 2, make: "Sony") == 1)
        #expect(CropFactor.nominal(format: 8, make: "OM Digital") == 2)
        #expect(CropFactor.nominal(format: 3, make: "Phase One") == nil)
    }

    /// The samples' crop factors, as `tests/fixtures` holds them.
    static let expected: [String: Double] = [
        "DSC_0750.NEF": 1, "_DSC0009.ARW": 1, "AFXT2720.RAF": 1.53, "Canon_EOS_R6_RAW_ISO_100_nocrop_nodual.CR3": 1,
        "Canon_EOS-R6-Mark-III.CR3": 1, "Canon_EOS-5D-Mark-IV.CR2": 1, "Fujifilm_X-T5.RAF": 1.53, "Nikon_Z-8.NEF": 1,
        "OM-System_OM-1-Mark-II.orf": 2, "Pentax_K-3-Mark-III.PEF": 1.53, "Sony_ILCE-7M4.ARW": 1,
    ]

    static let samples = (DecodeRegressionTests.fixtures + DecodeRegressionTests.cameras)
        .filter { expected[$0.lastPathComponent] != nil }

    @Test(.enabled(if: !samples.isEmpty), arguments: samples)
    func `each sample's crop factor`(url: URL) throws {
        let info = try ImageDecoder.decode(url).info
        #expect(info.cropFactor == Self.expected[url.lastPathComponent])
    }

    @Test(.enabled(if: DecodeRegressionTests.fixtures.contains { $0.lastPathComponent == "DSC_0750.NEF" }))
    func `a Nikon sample names its camera canonically and its lens's focal lengths`() throws {
        let url = try #require(DecodeRegressionTests.fixtures.first { $0.lastPathComponent == "DSC_0750.NEF" })
        let info = try ImageDecoder.decode(url).info
        #expect(info.canonicalMake == "Nikon" && info.canonicalModel == "Z 6")
        #expect(info.lensFocalRange == 24 ... 70)
        // A Z lens has a name, and no LensIDNumber.
        #expect(info.lens == "NIKKOR Z 24-70mm f/4 S" && info.lensID == nil)
    }

    @Test(.enabled(if: DecodeRegressionTests.cameras.contains { $0.lastPathComponent == "OM-System_OM-1-Mark-II.orf" }))
    func `an OM System sample's canonical name is LibRaw's Olympus one`() throws {
        let url = try #require(DecodeRegressionTests.cameras.first {
            $0.lastPathComponent == "OM-System_OM-1-Mark-II.orf"
        })
        let info = try ImageDecoder.decode(url).info
        #expect(info.make == "OM Digital" && info.canonicalMake == "Olympus" && info.canonicalModel == "OM-1 Mark II")
    }
}
