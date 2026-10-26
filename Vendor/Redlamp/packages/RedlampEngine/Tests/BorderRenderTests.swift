import CoreGraphics
import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampEngine

/// Borders around the photo (TON-53, TON-54): the canvas grows, the photo is untouched, and the
/// histogram counts only the photo.
struct BorderRenderTests {
    private static func edit(_ style: BorderStyle, _ values: [ParameterID: Double] = [:]) -> EditRecipe {
        var recipe = EditRecipe()
        recipe[.borderStyle] = Double(style.rawValue)
        for (parameter, value) in values {
            recipe[parameter] = value
        }
        return recipe
    }

    private static func pixel(_ pixels: [UInt8], width: Int, _ x: Int, _ y: Int) -> SIMD3<Int> {
        let o = (y * width + x) * 4
        return SIMD3(Int(pixels[o]), Int(pixels[o + 1]), Int(pixels[o + 2]))
    }

    @Test(.enabled(if: BaseLookTests.canRender))
    func `a 4:5 border grows the canvas and leaves the photo's pixels as they were`() async throws {
        let url = try FilmEffectsTests.flat(0.45, size: 600)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RedlampEngine()
        _ = try await engine.open(url)
        let plainImage = try await engine.renderStill(StillRequest(recipe: EditRecipe()))
        let plain = BaseLookTests.pixels(plainImage)
        let recipe = Self.edit(
            .plain,
            [.borderShape: Double(BorderShape.fourByFive.rawValue), .borderOrientation: 1, .borderSize: 0],
        )
        let image = try await engine.renderStill(StillRequest(recipe: recipe))
        #expect(image.width == 600 && image.height == 750)
        let bordered = BaseLookTests.pixels(image)
        #expect(Self.pixel(bordered, width: 600, 300, 10) == SIMD3(255, 255, 255))
        #expect(Self.pixel(bordered, width: 600, 300, 740) == SIMD3(255, 255, 255))
        #expect(Self.pixel(bordered, width: 600, 300, 75 + 300) == Self.pixel(plain, width: 600, 300, 300))
        #expect(Self.pixel(bordered, width: 600, 5, 76) == Self.pixel(plain, width: 600, 5, 1))
    }

    @Test(.enabled(if: BaseLookTests.canRender))
    func `an export's long edge includes the border`() async throws {
        let url = try FilmEffectsTests.flat(0.45, size: 600)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RedlampEngine()
        _ = try await engine.open(url)
        let recipe = Self.edit(
            .plain,
            [.borderShape: Double(BorderShape.fourByFive.rawValue), .borderOrientation: 1, .borderSize: 0],
        )
        for purpose in [StillPurpose.preview, .export] {
            let image = try await engine.renderStill(StillRequest(recipe: recipe, maxLongEdge: 300, purpose: purpose))
            #expect(image.width == 240 && image.height == 300, "\(purpose)")
        }
    }

    @Test(.enabled(if: BaseLookTests.canRender))
    func `a keyline sits around the photo in its own colour`() async throws {
        let url = try FilmEffectsTests.flat(0.45, size: 600)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RedlampEngine()
        _ = try await engine.open(url)
        // 5% of 600 is a 30 pixel margin; a 1% keyline 6 pixels wide, 1% (6 pixels) from the photo.
        let recipe = Self.edit(.plain, [.borderSize: 5, .borderKeylineWidth: 1, .borderKeylineGap: 1])
        let image = try await engine.renderStill(StillRequest(recipe: recipe))
        #expect(image.width == 660 && image.height == 660)
        let pixels = BaseLookTests.pixels(image)
        #expect(Self.pixel(pixels, width: 660, 330, 2) == SIMD3(255, 255, 255))
        #expect(Self.pixel(pixels, width: 660, 330, 30 - 9).x < 10, "the keyline")
        #expect(Self.pixel(pixels, width: 660, 330, 30 - 3) == SIMD3(255, 255, 255), "the gap")
    }

    @Test(.enabled(if: BaseLookTests.canRender))
    func `a still rendered in tiles draws the keyline on every side, the smaller last tiles included`() async throws {
        let url = try FilmEffectsTests.flat(0.45, size: 600)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RedlampEngine(stillTile: 256)
        _ = try await engine.open(url)
        var recipe = Self.edit(.plain, [.borderSize: 5, .borderKeylineWidth: 1, .borderKeylineGap: 1])
        recipe[.sharpenAmount] = 40
        let pixels = try await BaseLookTests.pixels(engine.renderStill(StillRequest(recipe: recipe)))
        // The photo spans 30...630 of 660; the keyline is 6 to 12 pixels out from it on each side.
        for (x, y) in [(330, 21), (21, 330), (639, 330), (330, 639)] {
            #expect(Self.pixel(pixels, width: 660, x, y).x < 10, "the keyline at \(x), \(y)")
        }
        for (x, y) in [(633, 330), (330, 633), (650, 330), (330, 650)] {
            #expect(Self.pixel(pixels, width: 660, x, y) == SIMD3(255, 255, 255), "white at \(x), \(y)")
        }
    }

    @Test(.enabled(if: BaseLookTests.canRender))
    func `the histogram counts the photo and not its white border`() async throws {
        let url = try FilmEffectsTests.flat(0.45, size: 600)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RedlampEngine()
        _ = try await engine.open(url)
        let frames = engine.frames()
        var iterator = frames.makeAsyncIterator()
        let recipe = Self.edit(.plain, [.borderShape: Double(BorderShape.square.rawValue), .borderSize: 10])
        engine.render(RenderRequest(recipe: recipe, targetSize: PixelSize(width: 800, height: 800), generation: 1))
        let frame = try #require(await iterator.next())
        #expect(frame.size == PixelSize(width: 720, height: 720))
        #expect(frame.histogram.totalCount > 0)
        #expect(frame.histogram.luminance[255] == 0, "white border pixels counted: \(frame.histogram.luminance[255])")
        #expect(!frame.histogram.highlightsClipped)
    }

    @Test(.enabled(if: BaseLookTests.canRender))
    func `a region of only border renders the border, and one across the edge matches the whole render`() async throws {
        let url = try FilmEffectsTests.flat(0.45, size: 600)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RedlampEngine()
        _ = try await engine.open(url)
        let recipe = Self.edit(.plain, [.borderSize: 10, .borderRed: 0, .borderGreen: 0, .borderBlue: 0])
        let whole = try await BaseLookTests.pixels(engine.renderStill(StillRequest(recipe: recipe)))
        let frames = engine.frames()
        var iterator = frames.makeAsyncIterator()
        // The canvas is 720 pixels; this region covers x 0...144, across the photo's left edge at 60.
        let region = ImageRect(x: 0, y: 0.4, width: 0.2, height: 0.2)
        engine.render(RenderRequest(
            recipe: recipe,
            targetSize: PixelSize(width: 144, height: 144),
            region: region,
            generation: 1,
        ))
        let part = try #require(await iterator.next())
        #expect(part.size == PixelSize(width: 144, height: 144))
        #expect(part.histogram.totalCount > 0)
        let corner = ImageRect(x: 0, y: 0, width: 0.05, height: 0.05)
        engine.render(RenderRequest(
            recipe: recipe,
            targetSize: PixelSize(width: 36, height: 36),
            region: corner,
            generation: 2,
        ))
        let border = try #require(await iterator.next())
        #expect(border.size == PixelSize(width: 36, height: 36))
        #expect(Self.pixel(whole, width: 720, 10, 300).x < 5, "black border")
    }

    @Test(.enabled(if: BaseLookTests.canRender))
    func `35 mm film shows its rebate, lit sprocket holes and edge print around the photo`() async throws {
        let url = try FilmEffectsTests.flat(0.45, size: 480)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RedlampEngine()
        _ = try await engine.open(url)
        // A square photo: 480 short side, so a frame unit (1 mm of a 24 mm frame) is 20 pixels.
        let image = try await engine.renderStill(StillRequest(recipe: Self.edit(.film35, [.borderFrameNumber: 12])))
        #expect(image.width == 480 + 80 && image.height == 480 + 220)
        let pixels = BaseLookTests.pixels(image)
        // The holes' centre row, 3 mm from the top edge: black film and lit holes.
        let row = (0 ..< image.width).map { Self.pixel(pixels, width: image.width, $0, 60).x }
        #expect(row.min() ?? 255 < 20 && row.max() ?? 0 > 200)
        // Edge print in the bottom strip, under 1.6 mm from the edge: orange dots.
        var ink = 0
        for y in (image.height - 32) ..< (image.height - 9) {
            for x in 0 ..< image.width {
                let p = Self.pixel(pixels, width: image.width, x, y)
                if p.x > 180, p.z < 120 {
                    ink += 1
                }
            }
        }
        #expect(ink > 50, "edge print dots: \(ink)")
    }

    @Test(.enabled(if: BaseLookTests.canRender))
    func `every style renders around the photo without touching it`() async throws {
        let url = try FilmEffectsTests.flat(0.45, size: 300)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RedlampEngine()
        _ = try await engine.open(url)
        let plain = try await BaseLookTests.pixels(engine.renderStill(StillRequest(recipe: EditRecipe())))
        let centre = Self.pixel(plain, width: 300, 150, 150)
        for style in BorderStyle.allCases where style != .none {
            let recipe = Self.edit(style)
            let layout = BorderLayout(recipe: recipe, photoSize: PixelSize(width: 300, height: 300))
            let image = try await engine.renderStill(StillRequest(recipe: recipe))
            #expect(image.width == layout.canvasSize.width && image.height == layout.canvasSize.height, "\(style)")
            let pixels = BaseLookTests.pixels(image)
            let x = Int((layout.photoRect.x + layout.photoRect.width / 2) * Double(image.width))
            let y = Int((layout.photoRect.y + layout.photoRect.height / 2) * Double(image.height))
            #expect(Self.pixel(pixels, width: image.width, x, y) == centre, "\(style)")
        }
    }
}
