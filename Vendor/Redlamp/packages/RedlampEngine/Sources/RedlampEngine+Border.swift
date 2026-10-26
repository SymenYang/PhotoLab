import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels

/// The photo's pixels in a rendered texture: all of it without a border, its rect inside one.
struct PhotoArea: Equatable {
    var x: Int
    var y: Int
    var size: PixelSize
}

extension RedlampEngine {
    /// Develops `recipe` into `texture`, which shows `region` of the developed photo at `size`. With
    /// `bordered`, `size` and `region` are the bordered canvas's (`BorderLayout`): the photo is
    /// developed into its rect and `rl_border` fills the pixels around it. Returns the photo's
    /// pixels, which the histogram reads, or nil when the region shows only border.
    @discardableResult
    func encodeDevelop(
        _ recipe: EditRecipe,
        session: ImageSession,
        into texture: any MTLTexture,
        size: PixelSize,
        region: ImageRect = .full,
        encoding: OutputEncoding,
        showClipping: Bool,
        maskOverlay: UUID? = nil,
        maskOverlayColor: MaskOverlayColor = .red,
        maskOverlayStyle: MaskOverlayStyle = .colorOverlay,
        maskOverlayOpacity: Double = MaskOverlayStyle.defaultOpacity,
        commands: any MTLCommandBuffer,
        cacheDetail: Bool = true,
        detail: Bool = true,
        visualizeSpots: Double? = nil,
        visualizePointColor: UUID? = nil,
        pointColorCoverage: Int? = nil,
        retouchMaps: RetouchStage.Maps = .current,
        bordered: Bool = false,
    ) throws -> PhotoArea? {
        let layout = bordered ? recipe.borderLayout(imageSize: session.orientedSize) : nil
        guard let layout, layout.hasBorder else {
            try encodePhoto(
                recipe, session: session, into: texture, size: size, region: region, encoding: encoding,
                showClipping: showClipping, maskOverlay: maskOverlay, maskOverlayColor: maskOverlayColor,
                maskOverlayStyle: maskOverlayStyle, maskOverlayOpacity: maskOverlayOpacity, commands: commands,
                cacheDetail: cacheDetail, detail: detail, visualizeSpots: visualizeSpots,
                visualizePointColor: visualizePointColor, pointColorCoverage: pointColorCoverage,
                retouchMaps: retouchMaps,
            )
            return PhotoArea(x: 0, y: 0, size: size)
        }
        let pixels = layout.photoPixels(in: region, size: size)
        if let pixels {
            try encodePhoto(
                recipe, session: session, into: texture, size: pixels.size, region: pixels.photoRegion,
                encoding: encoding, showClipping: showClipping, maskOverlay: maskOverlay,
                maskOverlayColor: maskOverlayColor, maskOverlayStyle: maskOverlayStyle,
                maskOverlayOpacity: maskOverlayOpacity, commands: commands, cacheDetail: cacheDetail, detail: detail,
                visualizeSpots: visualizeSpots, visualizePointColor: visualizePointColor,
                pointColorCoverage: pointColorCoverage, retouchMaps: retouchMaps, origin: pixels.origin,
            )
        }
        let area = pixels.map { PhotoArea(x: $0.origin.x, y: $0.origin.y, size: $0.size) }
        try encodeBorder(
            recipe, layout: layout, session: session, into: texture, size: size, region: region, area: area,
            encoding: encoding, commands: commands,
        )
        return area
    }

    /// Fills the border around `area` (the photo's pixels, if any) with `rl_border`.
    private func encodeBorder(
        _ recipe: EditRecipe,
        layout: BorderLayout,
        session: ImageSession,
        into texture: any MTLTexture,
        size: PixelSize,
        region: ImageRect,
        area: PhotoArea?,
        encoding: OutputEncoding,
        commands: any MTLCommandBuffer,
    ) throws {
        // Only the output primaries and encoding are read.
        var develop = DevelopParameters.make(
            recipe: recipe, session: session, baseLook: nil, outputSize: size, region: region, encoding: encoding,
            showClipping: false, maskOverlay: nil, maskOverlayColor: .red,
        ).params
        var params = Self.borderParams(
            recipe,
            layout: layout,
            size: size,
            region: region,
            area: area,
            file: session.info.url,
        )
        guard let encoder = commands.makeComputeCommandEncoder() else { throw EngineError.gpuUnavailable }
        encoder.setComputePipelineState(kernels.border)
        encoder.setTexture(texture, index: 0)
        encoder.setBytes(&develop, length: MemoryLayout<DevelopParams>.stride, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<BorderParams>.stride, index: 1)
        encoder.dispatchGrid(width: size.width, height: size.height, pipeline: kernels.border)
        encoder.endEncoding()
    }

    static func borderParams(
        _ recipe: EditRecipe, layout: BorderLayout, size: PixelSize, region: ImageRect, area: PhotoArea?, file: URL?,
    ) -> BorderParams {
        let recipe = recipe.rendered
        var params = BorderParams()
        if let area {
            params.photoPixels = SIMD4(
                Float(area.x), Float(area.y), Float(area.x + area.size.width), Float(area.y + area.size.height),
            )
        }
        params.region = SIMD4(Float(region.x), Float(region.y), Float(region.width), Float(region.height))
        params.area = SIMD4(Float(size.width), Float(size.height), 0, 0)
        let aspect = Double(layout.canvasSize.width) / Double(max(layout.canvasSize.height, 1))
        params.canvas = SIMD4(Float(aspect), Float(layout.style.rawValue), 0, 0)
        let rect = layout.photoRect
        params.photo = SIMD4(
            Float(rect.x * aspect), Float(rect.y), Float(rect.width * aspect), Float(rect.height),
        )
        func color(_ red: ParameterID, _ green: ParameterID, _ blue: ParameterID) -> SIMD4<Float> {
            SIMD4(Float(recipe[red] / 255), Float(recipe[green] / 255), Float(recipe[blue] / 255), 1)
        }
        params.color = color(.borderRed, .borderGreen, .borderBlue)
        params.keylineColor = color(.borderKeylineRed, .borderKeylineGreen, .borderKeylineBlue)
        // Percent of the photo's long side, in canvas heights.
        let longSide = Double(max(layout.photoSize.width, layout.photoSize.height)) / Double(layout.canvasSize.height)
        params.keyline = SIMD4(
            Float(recipe[.borderKeylineWidth] / 100 * longSide), Float(recipe[.borderKeylineGap] / 100 * longSide), 0,
            0,
        )
        if layout.style.isFilm, recipe[.borderEdgePrint] > 0.5 {
            params.setText(BorderGlyphs.codes(edgePrint(recipe, style: layout.style, file: file)))
        }
        return params
    }

    /// What a film frame's edge prints: its number, and on 35 mm the half-frame mark beside an
    /// arrow, then the film look's name when the photo's Base Look is a film stock.
    static func edgePrint(_ recipe: EditRecipe, style: BorderStyle, file: URL?) -> String {
        let number = frameNumber(recipe, file: file)
        var text = style == .film35 ? "\(number)   >\(number)A" : "\(number)"
        let look = recipe.baseLook
        if look.id.contains("/stock/") {
            let name = look.name.components(separatedBy: " · ").first ?? look.name
            text += "      " + name
        }
        return text
    }

    /// The frame number the edit sets, or 1 to 36 from the last digits of the file's name, so a set
    /// of photos reads as a roll.
    static func frameNumber(_ recipe: EditRecipe, file: URL?) -> Int {
        let chosen = Int(recipe[.borderFrameNumber].rounded())
        if chosen > 0 {
            return chosen
        }
        let name = file?.deletingPathExtension().lastPathComponent ?? ""
        let digits = name.reversed().drop { !$0.isNumber }.prefix { $0.isNumber }
        guard let value = Int(String(digits.reversed().suffix(6))) else { return 1 }
        return (value + 35) % 36 + 1
    }
}
