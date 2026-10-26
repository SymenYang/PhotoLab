import Foundation

/// The borders `ParameterID.borderStyle` draws around the photo.
///
/// Sidecars store a style as its raw value. Never change or reuse one: existing edits would draw a
/// different border.
public enum BorderStyle: Int, CaseIterable, Sendable {
    case none = 0
    case plain = 1
    case film35 = 2
    case mediumFormat = 3
    case instantSquare = 4
    case instantMini = 5
    case instantWide = 6
    case slideMount = 7
    case slideMountPlastic = 8
    case filedCarrier = 9

    public var name: String {
        switch self {
        case .none: "None"
        case .plain: "Plain"
        case .film35: "35 mm Film"
        case .mediumFormat: "Medium Format"
        case .instantSquare: "Instant Square"
        case .instantMini: "Instant Mini"
        case .instantWide: "Instant Wide"
        case .slideMount: "Slide Mount"
        case .slideMountPlastic: "Slide Mount (Plastic)"
        case .filedCarrier: "Filed Carrier"
        }
    }

    /// Whether Shape, Size and Position apply; film and instant styles take their format's proportions.
    public var isShaped: Bool {
        self == .plain
    }

    /// Whether the border's colour applies (the paper, card or mount).
    public var usesColor: Bool {
        switch self {
        case .plain, .instantSquare, .instantMini, .instantWide, .slideMount, .slideMountPlastic, .filedCarrier: true
        case .none, .film35, .mediumFormat: false
        }
    }

    /// Film rebates, which carry edge print.
    public var isFilm: Bool {
        self == .film35 || self == .mediumFormat
    }

    /// The shape of the frame's window, short side over long side, for Crop to Format.
    public var formatAspect: Double? {
        switch self {
        case .film35, .slideMount, .slideMountPlastic: 24.0 / 36
        case .mediumFormat, .instantSquare: 1
        case .instantMini: 46.0 / 62
        case .instantWide: 62.0 / 99
        case .none, .plain, .filedCarrier: nil
        }
    }

    /// Whether the format's window is portrait whatever the photo (an instant mini card).
    public var formatIsPortrait: Bool {
        self == .instantMini
    }
}

/// The shapes a Plain border's canvas takes, short side to long side (`ParameterID.borderShape`).
///
/// Sidecars store a shape as its raw value. Never change or reuse one.
public enum BorderShape: Int, CaseIterable, Sendable {
    case even = 0
    case square = 1
    case fourByFive = 2
    case threeByFour = 3
    case twoByThree = 4
    case nineBySixteen = 5
    case fiveBySeven = 6
    case elevenByFourteen = 7
    case aPaper = 8
    case custom = 9

    public var name: String {
        switch self {
        case .even: "Even"
        case .square: "1:1"
        case .fourByFive: "4:5"
        case .threeByFour: "3:4"
        case .twoByThree: "2:3"
        case .nineBySixteen: "9:16"
        case .fiveBySeven: "5:7"
        case .elevenByFourteen: "11:14"
        case .aPaper: "A Paper"
        case .custom: "Custom"
        }
    }

    /// Short side over long side; nil for Even and Custom.
    public var ratio: Double? {
        switch self {
        case .even, .custom: nil
        case .square: 1
        case .fourByFive: 4.0 / 5
        case .threeByFour: 3.0 / 4
        case .twoByThree: 2.0 / 3
        case .nineBySixteen: 9.0 / 16
        case .fiveBySeven: 5.0 / 7
        case .elevenByFourteen: 11.0 / 14
        case .aPaper: 1 / 2.0.squareRoot()
        }
    }
}

/// Which way round a shaped canvas is (`ParameterID.borderOrientation`).
public enum BorderOrientation: Int, CaseIterable, Sendable {
    /// Turned with the photo, as a print on paper is.
    case matchPhoto = 0
    case portrait = 1
    case landscape = 2

    public var name: String {
        switch self {
        case .matchPhoto: "Match Photo"
        case .portrait: "Portrait"
        case .landscape: "Landscape"
        }
    }
}

/// Where a border puts the photo: the canvas it grows to and the photo's rect in it. Computed from
/// the edit's `border.*` settings and the developed photo's size, so the canvas, stills, thumbnails
/// and exports agree on the bordered size.
public struct BorderLayout: Sendable, Equatable {
    public let style: BorderStyle
    /// The developed photo, in its own pixels.
    public let photoSize: PixelSize
    /// The bordered canvas, at the photo's resolution.
    public let canvasSize: PixelSize
    /// The photo within the canvas, normalized (0...1 of the canvas's width and height).
    public let photoRect: ImageRect

    /// Whether the edit draws a border at all.
    public var hasBorder: Bool {
        style != .none
    }

    private init(style: BorderStyle, photoSize: PixelSize, canvasSize: PixelSize, photoRect: ImageRect) {
        self.style = style
        self.photoSize = photoSize
        self.canvasSize = canvasSize
        self.photoRect = photoRect
    }

    /// No border: the canvas is the photo.
    public init(photoSize: PixelSize) {
        self.init(style: .none, photoSize: photoSize, canvasSize: photoSize, photoRect: .full)
    }

    public init(recipe: EditRecipe, photoSize: PixelSize) {
        let recipe = recipe.rendered
        let style = BorderStyle(rawValue: Int(recipe[.borderStyle].rounded())) ?? .none
        guard style != .none, photoSize.width > 0, photoSize.height > 0 else {
            self.init(photoSize: photoSize)
            return
        }
        let margins = Self.margins(style: style, recipe: recipe, photo: photoSize)
        let width = Double(photoSize.width) + margins.left + margins.right
        let height = Double(photoSize.height) + margins.top + margins.bottom
        let canvas = PixelSize(width: max(1, Int(width.rounded())), height: max(1, Int(height.rounded())))
        self.init(
            style: style, photoSize: photoSize, canvasSize: canvas,
            photoRect: ImageRect(
                x: margins.left / Double(canvas.width), y: margins.top / Double(canvas.height),
                width: Double(photoSize.width) / Double(canvas.width),
                height: Double(photoSize.height) / Double(canvas.height),
            ),
        )
    }

    struct Margins: Equatable {
        var left: Double
        var top: Double
        var right: Double
        var bottom: Double
    }

    /// Each style's margins in photo pixels. Film and instant frames follow their formats' published
    /// dimensions (docs/plans/2026-10-16-borders-design.md), scaled to the photo.
    static func margins(style: BorderStyle, recipe: EditRecipe, photo: PixelSize) -> Margins {
        let w = Double(photo.width), h = Double(photo.height)
        let short = min(w, h), long = max(w, h)
        let landscape = w >= h
        func alongFilm(edge: Double, gap: Double) -> Margins {
            // The rebate runs along the long sides, the gap to the next frame on the short ones.
            landscape
                ? Margins(left: gap, top: edge, right: gap, bottom: edge)
                : Margins(left: edge, top: gap, right: edge, bottom: gap)
        }
        switch style {
        case .none:
            return Margins(left: 0, top: 0, right: 0, bottom: 0)
        case .plain:
            return plainMargins(recipe: recipe, width: w, height: h)
        case .film35:
            // 35 mm film around a 24 mm frame: 5.5 mm of rebate a side, 2 mm to the next frame.
            return alongFilm(edge: short * 5.5 / 24, gap: short * 2 / 24)
        case .mediumFormat:
            // 120 film, 61 mm around a 56 mm frame, with about 3 mm to the next frame.
            return alongFilm(edge: short * 2.5 / 56, gap: short * 3 / 56)
        case .instantSquare:
            let unit = w / 62
            return Margins(left: 5 * unit, top: 5 * unit, right: 5 * unit, bottom: 19 * unit)
        case .instantMini:
            let unit = w / 46
            return Margins(left: 4 * unit, top: 7 * unit, right: 4 * unit, bottom: 17 * unit)
        case .instantWide:
            let unit = w / 99
            return Margins(left: 4.5 * unit, top: 7 * unit, right: 4.5 * unit, bottom: 17 * unit)
        case .slideMount, .slideMountPlastic:
            // A 50 mm square mount around a 36 mm long window.
            let side = long * 50 / 36
            return Margins(left: (side - w) / 2, top: (side - h) / 2, right: (side - w) / 2, bottom: (side - h) / 2)
        case .filedCarrier:
            let margin = short * 0.11
            return Margins(left: margin, top: margin, right: margin, bottom: margin)
        }
    }

    static func plainMargins(recipe: EditRecipe, width w: Double, height h: Double) -> Margins {
        let margin = max(0, recipe[.borderSize]) / 100 * max(w, h)
        var canvasWidth = w + 2 * margin
        var canvasHeight = h + 2 * margin
        let shape = BorderShape(rawValue: Int(recipe[.borderShape].rounded())) ?? .even
        let ratio: Double? = switch shape {
        case .even: nil
        case .custom:
            min(recipe[.borderRatioWidth], recipe[.borderRatioHeight])
                / max(recipe[.borderRatioWidth], recipe[.borderRatioHeight], 1)
        default: shape.ratio
        }
        if let ratio, ratio > 0 {
            let orientation = BorderOrientation(rawValue: Int(recipe[.borderOrientation].rounded())) ?? .matchPhoto
            let portrait = switch orientation {
            case .matchPhoto: h > w
            case .portrait: true
            case .landscape: false
            }
            // Width over height.
            let aspect = portrait ? ratio : 1 / ratio
            if canvasWidth / canvasHeight > aspect {
                canvasHeight = canvasWidth / aspect
            } else {
                canvasWidth = canvasHeight * aspect
            }
        }
        let spareX = canvasWidth - w, spareY = canvasHeight - h
        let x = min(max(recipe[.borderOffsetX] / 100, -1), 1)
        let y = min(max(recipe[.borderOffsetY] / 100, -1), 1)
        return Margins(
            left: spareX / 2 * (1 + x), top: spareY / 2 * (1 - y),
            right: spareX / 2 * (1 - x), bottom: spareY / 2 * (1 + y),
        )
    }

    /// The photo's rect in pixels of a texture of `size` that shows `region` of the canvas, and the
    /// part of the photo that rect shows. Nil when the region shows none of the photo.
    public func photoPixels(
        in region: ImageRect,
        size: PixelSize,
    ) -> (origin: (x: Int, y: Int), size: PixelSize, photoRegion: ImageRect)? {
        let left = max(region.x, photoRect.x), top = max(region.y, photoRect.y)
        let right = min(region.x + region.width, photoRect.x + photoRect.width)
        let bottom = min(region.y + region.height, photoRect.y + photoRect.height)
        guard right > left, bottom > top, region.width > 0, region.height > 0 else { return nil }
        func pixel(_ value: Double, _ origin: Double, _ extent: Double, _ count: Int) -> Int {
            min(max(Int(((value - origin) / extent * Double(count)).rounded()), 0), count)
        }
        let x0 = pixel(left, region.x, region.width, size.width)
        let x1 = pixel(right, region.x, region.width, size.width)
        let y0 = pixel(top, region.y, region.height, size.height)
        let y1 = pixel(bottom, region.y, region.height, size.height)
        guard x1 > x0, y1 > y0 else { return nil }
        /// The part of the photo those whole pixels cover, so the photo lands exactly on them.
        func canvas(_ pixel: Int, _ origin: Double, _ extent: Double, _ count: Int) -> Double {
            origin + Double(pixel) / Double(count) * extent
        }
        let cx0 = canvas(x0, region.x, region.width, size.width), cx1 = canvas(x1, region.x, region.width, size.width)
        let cy0 = canvas(y0, region.y, region.height, size.height)
        let cy1 = canvas(y1, region.y, region.height, size.height)
        let photoRegion = ImageRect(
            x: (cx0 - photoRect.x) / photoRect.width, y: (cy0 - photoRect.y) / photoRect.height,
            width: (cx1 - cx0) / photoRect.width, height: (cy1 - cy0) / photoRect.height,
        )
        return ((x0, y0), PixelSize(width: x1 - x0, height: y1 - y0), photoRegion)
    }

    /// The photo point (0...1 of the photo) at a canvas point (0...1 of the canvas), or nil in the border.
    public func photoPoint(_ canvas: SIMD2<Double>) -> SIMD2<Double>? {
        let point = SIMD2(
            (canvas.x - photoRect.x) / photoRect.width, (canvas.y - photoRect.y) / photoRect.height,
        )
        guard point.x >= 0, point.y >= 0, point.x <= 1, point.y <= 1 else { return nil }
        return point
    }

    /// Where a photo point (0...1 of the photo) lands on the canvas (0...1).
    public func canvasPoint(_ photo: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2(photoRect.x + photo.x * photoRect.width, photoRect.y + photo.y * photoRect.height)
    }
}

public extension ParameterID {
    /// Whether the parameter is a choice (a style, a shape, a switch) rather than an amount: never
    /// blended between values.
    var isChoice: Bool {
        switch self {
        case .frameStyle, .borderStyle, .borderShape, .borderOrientation, .borderEdgePrint, .borderFrameNumber: true
        default: false
        }
    }
}

public extension EditRecipe {
    /// The parameters of the Border panel.
    static let borderParameters: [ParameterID] = ParameterID.allCases.filter { $0.rawValue.hasPrefix("border.") }

    /// The border around the developed photo, for a photo of `imageSize` (EXIF-oriented).
    func borderLayout(imageSize: PixelSize) -> BorderLayout {
        BorderLayout(recipe: self, photoSize: developedSize(imageSize: imageSize))
    }

    /// The bordered canvas's size: the developed photo with its border, the size of every render.
    func borderedSize(imageSize: PixelSize) -> PixelSize {
        borderLayout(imageSize: imageSize).canvasSize
    }

    /// This edit without its border, as the crop tool and the colour-assessment view show it.
    func withoutBorder() -> EditRecipe {
        var edit = self
        edit[.borderStyle] = 0
        return edit
    }
}
