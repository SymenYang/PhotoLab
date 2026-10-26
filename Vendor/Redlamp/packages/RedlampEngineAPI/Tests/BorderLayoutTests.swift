import Foundation
import Testing
@testable import RedlampEngineAPI

struct BorderLayoutTests {
    private func plain(
        _ shape: BorderShape, orientation: BorderOrientation = .matchPhoto, size: Double = 4, x: Double = 0,
        y: Double = 0,
    ) -> EditRecipe {
        var edit = EditRecipe()
        edit[.borderStyle] = Double(BorderStyle.plain.rawValue)
        edit[.borderShape] = Double(shape.rawValue)
        edit[.borderOrientation] = Double(orientation.rawValue)
        edit[.borderSize] = size
        edit[.borderOffsetX] = x
        edit[.borderOffsetY] = y
        return edit
    }

    private let landscape = PixelSize(width: 6000, height: 4000)
    private let portrait = PixelSize(width: 4000, height: 6000)

    @Test func `no border leaves the canvas as the photo`() {
        let layout = BorderLayout(recipe: EditRecipe(), photoSize: landscape)
        #expect(!layout.hasBorder)
        #expect(layout.canvasSize == landscape)
        #expect(layout.photoRect == .full)
    }

    @Test func `an even border adds the same margin on every side, a share of the long side`() {
        let layout = BorderLayout(recipe: plain(.even, size: 5), photoSize: landscape)
        #expect(layout.canvasSize == PixelSize(width: 6600, height: 4600))
        #expect(abs(layout.photoRect.x * 6600 - 300) < 1e-6)
        #expect(abs(layout.photoRect.y * 4600 - 300) < 1e-6)
    }

    @Test func `portrait 4:5 puts a landscape photo on a tall canvas with its margin at the sides`() {
        let layout = BorderLayout(recipe: plain(.fourByFive, orientation: .portrait, size: 2), photoSize: landscape)
        // 6000 + 2 × 120 wide, so 6240 × 7800.
        #expect(layout.canvasSize == PixelSize(width: 6240, height: 7800))
        #expect(abs(layout.photoRect.x * 6240 - 120) < 1e-6)
        #expect(abs(layout.photoRect.y * 7800 - 1900) < 1e-6)
    }

    @Test func `match photo turns the shape with the photo`() {
        let wide = BorderLayout(recipe: plain(.fourByFive, size: 0), photoSize: landscape)
        let tall = BorderLayout(recipe: plain(.fourByFive, size: 0), photoSize: portrait)
        #expect(abs(wide.canvasSize.aspectRatio - 5.0 / 4) < 1e-3)
        #expect(abs(tall.canvasSize.aspectRatio - 4.0 / 5) < 1e-3)
    }

    @Test func `every shape holds the whole photo with at least its margin`() {
        for shape in BorderShape.allCases {
            for orientation in BorderOrientation.allCases {
                for photo in [landscape, portrait, PixelSize(width: 3000, height: 3000)] {
                    let layout = BorderLayout(recipe: plain(shape, orientation: orientation, size: 3), photoSize: photo)
                    let margin = 0.03 * Double(max(photo.width, photo.height))
                    let left = layout.photoRect.x * Double(layout.canvasSize.width)
                    let top = layout.photoRect.y * Double(layout.canvasSize.height)
                    let right = Double(layout.canvasSize.width) - left - Double(photo.width)
                    let bottom = Double(layout.canvasSize.height) - top - Double(photo.height)
                    #expect(min(left, right, top, bottom) >= margin - 1, "\(shape) \(orientation) \(photo)")
                }
            }
        }
    }

    @Test func `raising the photo moves the spare margin below it`() {
        let layout = BorderLayout(recipe: plain(.even, size: 5, y: 50), photoSize: landscape)
        let top = layout.photoRect.y * Double(layout.canvasSize.height)
        let bottom = Double(layout.canvasSize.height) - top - 4000
        #expect(abs(top - 150) < 1e-6)
        #expect(abs(bottom - 450) < 1e-6)
    }

    @Test func `an instant square card has a heavier bottom`() {
        var edit = EditRecipe()
        edit[.borderStyle] = Double(BorderStyle.instantSquare.rawValue)
        let layout = BorderLayout(recipe: edit, photoSize: PixelSize(width: 6200, height: 6200))
        #expect(layout.canvasSize == PixelSize(width: 7200, height: 8600))
    }

    @Test func `the 35 mm rebate runs along the photo's long sides`() {
        var edit = EditRecipe()
        edit[.borderStyle] = Double(BorderStyle.film35.rawValue)
        let wide = BorderLayout(recipe: edit, photoSize: PixelSize(width: 3600, height: 2400))
        #expect(wide.canvasSize == PixelSize(width: 4000, height: 3500))
        let tall = BorderLayout(recipe: edit, photoSize: PixelSize(width: 2400, height: 3600))
        #expect(tall.canvasSize == PixelSize(width: 3500, height: 4000))
    }

    @Test func `the border panel's switch takes the border away`() {
        var edit = plain(.square)
        edit.setPanel(.border, on: false)
        #expect(!BorderLayout(recipe: edit, photoSize: landscape).hasBorder)
    }

    @Test func `the photo's pixels in a region land exactly on whole pixels`() throws {
        let layout = BorderLayout(recipe: plain(.even, size: 5), photoSize: landscape)
        let whole = try #require(layout.photoPixels(in: .full, size: layout.canvasSize))
        #expect(whole.origin.x == 300 && whole.origin.y == 300)
        #expect(whole.size == landscape)
        // A region of only border shows none of the photo.
        #expect(layout.photoPixels(
            in: ImageRect(x: 0, y: 0, width: 0.02, height: 0.02),
            size: PixelSize(width: 100, height: 100),
        ) == nil)
        // A region across the photo's left edge.
        let edge = try #require(layout.photoPixels(
            in: ImageRect(x: 0, y: 0.4, width: 0.1, height: 0.1), size: PixelSize(width: 660, height: 460),
        ))
        #expect(edge.origin.x == 300)
        #expect(abs(edge.photoRegion.x) < 1e-9)
    }

    @Test func `points in the border aren't on the photo`() {
        let layout = BorderLayout(recipe: plain(.even, size: 5), photoSize: landscape)
        #expect(layout.photoPoint(SIMD2(0.01, 0.5)) == nil)
        let centre = layout.photoPoint(SIMD2(0.5, 0.5))
        #expect(centre.map { abs($0.x - 0.5) < 1e-9 && abs($0.y - 0.5) < 1e-9 } == true)
    }

    @Test func `copying settings leaves the border out unless it's ticked`() throws {
        let item = try #require(SettingsGroup.allItems.first { $0.id == "border" })
        #expect(!SettingsSelection.default.includes(item))
    }
}
