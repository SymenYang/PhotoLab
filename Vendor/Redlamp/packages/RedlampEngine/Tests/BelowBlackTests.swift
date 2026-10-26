import Foundation
import Metal
import RedlampEngineAPI
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// Values below black kept until after noise reduction (DN-12). From the third raw revision
/// (process 16), the noise of a dark patch averages to the patch's own level; the clamp at
/// normalisation lifted it instead and, white balance amplifying red and blue, tinted it magenta
/// (DN-11 §5.5).
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct BelowBlackTests {
    let detail: DetailStageTests

    init() throws {
        detail = try DetailStageTests()
    }

    /// DN-11's dark patch, a neutral at 0.017 once white-balanced.
    static let patch: Float = 0.017
    /// Noise like ISO 51200's: seven times `DetailStageTests.noise`'s sigma, which the photo's
    /// noise profile says.
    static let noiseScale: Float = 7
    static let profile = NoiseModel(a: DetailStageTests.noise.a * 49, b: DetailStageTests.noise.b * 49)

    @Test(arguments: [SensorKind.bayer, .xTrans])
    func `a dark patch averages to its own level at the third revision`(sensor: SensorKind) throws {
        let third = try Self.mean(detail.readLevel(darkPatch(sensor, revision: .third), level: 0), width: 1024)
        let second = try Self.mean(detail.readLevel(darkPatch(sensor, revision: .second), level: 0), width: 1024)
        for channel in 0 ..< 3 {
            #expect(abs(third[channel] / Self.patch - 1) < 0.03, "\(sensor), channel \(channel): \(third)")
        }
        #expect(second.x / Self.patch > 1.2 && second.z / Self.patch > 1.15, "\(sensor): \(second)")
    }

    /// The photo opens at the third revision and keeps its raw source, so an edit at process 15
    /// renders from a variant built at the second, pixel for pixel as a photo built there renders it.
    @Test func `an edit at process 15 renders exactly as the second revision built it`() throws {
        let engine = try RedlampEngine()
        let photo = try darkPatch(.bayer, revision: .third)
        #expect(photo.rawSource != nil)
        let secondBuilt = try darkPatch(.bayer, revision: .second)
        var recipe = EditRecipe()
        recipe.processVersion = 15
        let request = RenderRequest(recipe: recipe, targetSize: PixelSize(width: 256, height: 128))
        let older = try HighlightReconstructionTests.pixels(engine.renderFrame(request, session: photo))
        let built = try HighlightReconstructionTests.pixels(engine.renderFrame(request, session: secondBuilt))
        #expect(older == built)
        #expect(engine.revisions.variantsBuilt == 1)
    }

    /// Nothing below black and nothing clipped: every revision builds the same pyramid, so the
    /// photo keeps no raw source.
    @Test func `a photo with nothing below black keeps no raw source`() throws {
        let third = try darkPatch(.bayer, revision: .third, noiseScale: 0)
        let second = try darkPatch(.bayer, revision: .second, noiseScale: 0)
        #expect(third.rawSource == nil)
        #expect(try detail.readLevel(third, level: 0) == detail.readLevel(second, level: 0))
    }

    /// Through noise reduction and the develop kernel, at half size: at process 16 the noisy patch is
    /// nearly as neutral as a noise-free one, where at process 15 the clamp tints it magenta. Its
    /// level isn't the clean one's: noise reduction's inverse transform reads a noisy shadow's mean
    /// low, as it does at process 15 wherever the clamp didn't lift it.
    @Test func `a noisy dark patch renders neutral at process 16`() throws {
        let engine = try RedlampEngine()
        let noisy = try darkPatch(.bayer, revision: .third)
        let clean = try darkPatch(.bayer, revision: .third, noiseScale: 0)
        let size = PixelSize(width: 512, height: 256)
        let truth = try rendered(clean, process: 16, size: size, engine: engine)
        let kept = try rendered(noisy, process: 16, size: size, engine: engine)
        let clamped = try rendered(noisy, process: 15, size: size, engine: engine)
        /// Red and blue against green, as shares of the noise-free patch's.
        func tint(_ colour: SIMD3<Float>) -> (red: Float, blue: Float) {
            let red = colour.x / colour.y / (truth.x / truth.y)
            let blue = colour.z / colour.y / (truth.z / truth.y)
            return (red - 1, blue - 1)
        }
        #expect(abs(tint(kept).red) < 0.04 && abs(tint(kept).blue) < 0.04, "\(kept) against \(truth)")
        #expect(tint(clamped).red > 0.05 && tint(clamped).blue > 0.05, "\(clamped) against \(truth)")
    }

    /// Seen whole, the pyramid's levels have averaged the noise before anything clamps it: at
    /// process 16 the noisy patch renders as dark as a noise-free one, where at process 15 it's lifted.
    @Test func `a noisy dark patch seen whole renders as dark as a clean one at process 16`() throws {
        let engine = try RedlampEngine()
        let noisy = try darkPatch(.bayer, revision: .third)
        let clean = try darkPatch(.bayer, revision: .third, noiseScale: 0)
        let size = PixelSize(width: 128, height: 64)
        let truth = try rendered(clean, process: 16, size: size, engine: engine)
        let kept = try rendered(noisy, process: 16, size: size, engine: engine)
        let clamped = try rendered(noisy, process: 15, size: size, engine: engine)
        for channel in 0 ..< 3 {
            #expect(abs(kept[channel] / truth[channel] - 1) < 0.03, "channel \(channel): \(kept) against \(truth)")
        }
        #expect(clamped.x / truth.x > 1.1 && clamped.z / truth.z > 1.1, "\(clamped) against \(truth)")
    }

    /// An edit made before process 16, known before its photo opens: the photo is built at the
    /// edit's revision, and the edit renders without building it again.
    @Test func `a photo opens at the revision its edit is expected to need`() async throws {
        let url = try #require(EngineSmokeTests.fixtures.first { $0.lastPathComponent == "_DSC0009.ARW" })
        let engine = try RedlampEngine()
        engine.expect(.second, for: url)
        _ = try await engine.open(url)
        let photo = try #require(engine.currentSession())
        #expect(photo.rawRevision == .second && photo.rawSource != nil)
        var recipe = EditRecipe()
        recipe.processVersion = 15
        _ = try engine.renderFrame(
            RenderRequest(recipe: recipe, targetSize: PixelSize(width: 300, height: 200)),
            session: photo,
        )
        #expect(engine.revisions.variantsBuilt == 0)
        recipe.processVersion = 16
        _ = try engine.renderFrame(
            RenderRequest(recipe: recipe, targetSize: PixelSize(width: 300, height: 200)),
            session: photo,
        )
        #expect(engine.revisions.variantsBuilt == 1)
    }

    // MARK: - Helpers

    /// The dark patch over the whole frame, as a camera balanced by `daylight` records it.
    func darkPatch(
        _ sensor: SensorKind, revision: RawRevision, noiseScale: Float = BelowBlackTests.noiseScale,
    ) throws -> ImageSession {
        let daylight = HighlightReconstructionTests.daylight
        return try detail.makeSession(
            sensor, width: 1024, height: 512, noiseScale: noiseScale, asShot: daylight, profile: Self.profile,
            revision: revision,
        ) { x, y in
            Self.patch / Float(daylight[HighlightReconstructionTests.channel(sensor, x, y)])
        }
    }

    /// The mean colour of `session` rendered at `size`, with Luminance noise reduction at 60.
    func rendered(_ session: ImageSession, process: Int, size: PixelSize, engine: RedlampEngine) throws
        -> SIMD3<Float> {
        var recipe = EditRecipe()
        recipe.processVersion = process
        recipe[.noiseLuminance] = 60
        let frame = try engine.renderFrame(RenderRequest(recipe: recipe, targetSize: size), session: session)
        return Self.mean(HighlightReconstructionTests.pixels(frame), width: size.width)
    }

    /// The mean colour away from the frame's edges, where the demosaics read beyond it.
    static func mean(_ pixels: [SIMD3<Float>], width: Int) -> SIMD3<Float> {
        let height = pixels.count / width
        let margin = width / 32
        var total = SIMD3<Double>.zero
        var count = 0.0
        for y in margin ..< height - margin {
            for x in margin ..< width - margin {
                total += SIMD3<Double>(pixels[y * width + x])
                count += 1
            }
        }
        return SIMD3<Float>(total / count)
    }
}
