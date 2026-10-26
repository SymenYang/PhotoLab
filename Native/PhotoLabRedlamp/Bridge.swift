import Foundation
import CoreGraphics
import RedlampEngine
import RedlampEngineAPI
import RedlampServices

private final class Reply<Value: Sendable>: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<Value, Error>?
}

private func blocking<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) throws -> Value {
    let reply = Reply<Value>()
    Task.detached {
        do { reply.result = .success(try await operation()) }
        catch { reply.result = .failure(error) }
        reply.semaphore.signal()
    }
    reply.semaphore.wait()
    return try reply.result!.get()
}

private final class EngineSession: @unchecked Sendable {
    let engine: RedlampEngine
    var input: URL?
    var info: ImageInfo?
    var autoBalance: WhiteBalanceValue?
    init() throws { engine = try RedlampEngine(decoder: InProcessDecoder(), lensProfiles: .user, cameraProfiles: .user) }
    func open(_ url: URL) throws -> ImageInfo {
        if input == url, let info { return info }
        let opened = try blocking { [engine] in try await engine.open(url) }
        input = url; info = opened; autoBalance = nil
        return opened
    }
    func render(_ data: Data, edge: Int, exporting: Bool) throws -> CGImage {
        var recipe = try JSONDecoder().decode(EditRecipe.self, from: data)
        let mode = recipe.whiteBalanceMode
        if mode == .auto, autoBalance == nil { autoBalance = try blocking { [engine] in await engine.autoWhiteBalance() } }
        if let balance = mode == .auto ? autoBalance : mode.presetValue {
            recipe[.temperature] = balance.temperature; recipe[.tint] = balance.tint
        }
        let request = StillRequest(recipe: recipe, maxLongEdge: edge > 0 ? edge : nil,
                                   colorSpace: .sRGB, bitsPerComponent: exporting ? 16 : 8,
                                   purpose: exporting ? .export : .preview)
        return try blocking { [engine] in try await engine.renderStill(request) }
    }
}

private func report(_ error: Error, _ destination: UnsafeMutablePointer<CChar>?, _ capacity: Int32) {
    guard let destination, capacity > 0 else { return }
    let bytes = Array(String(describing: error).utf8.prefix(Int(capacity) - 1))
    for (index, byte) in bytes.enumerated() { destination[index] = CChar(bitPattern: byte) }
    destination[bytes.count] = 0
}

@_cdecl("photolab_redlamp_abi")
public func abi() -> Int32 { 1 }

@_cdecl("photolab_redlamp_create")
public func create(_ errorBuffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> UnsafeMutableRawPointer? {
    do { return Unmanaged.passRetained(try EngineSession()).toOpaque() }
    catch { report(error, errorBuffer, capacity); return nil }
}

@_cdecl("photolab_redlamp_destroy")
public func destroy(_ pointer: UnsafeMutableRawPointer) {
    let session = Unmanaged<EngineSession>.fromOpaque(pointer).takeRetainedValue()
    try? blocking { await session.engine.releaseResources() }
}

@_cdecl("photolab_redlamp_open")
public func openImage(_ pointer: UnsafeMutableRawPointer, _ path: UnsafePointer<CChar>,
                      _ width: UnsafeMutablePointer<Int32>, _ height: UnsafeMutablePointer<Int32>,
                      _ errorBuffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
    do {
        let session = Unmanaged<EngineSession>.fromOpaque(pointer).takeUnretainedValue()
        let info = try session.open(URL(fileURLWithPath: String(cString: path)))
        width.pointee = Int32(info.pixelSize.width); height.pointee = Int32(info.pixelSize.height)
        return 1
    } catch { report(error, errorBuffer, capacity); return 0 }
}

@_cdecl("photolab_redlamp_render")
public func renderImage(_ pointer: UnsafeMutableRawPointer, _ json: UnsafePointer<UInt8>, _ length: Int32,
                        _ edge: Int32, _ exporting: Int32, _ errorBuffer: UnsafeMutablePointer<CChar>?,
                        _ capacity: Int32) -> UnsafeMutableRawPointer? {
    do {
        let session = Unmanaged<EngineSession>.fromOpaque(pointer).takeUnretainedValue()
        let result = try session.render(Data(bytes: json, count: Int(length)), edge: Int(edge), exporting: exporting != 0)
        return Unmanaged.passRetained(result).toOpaque()
    } catch { report(error, errorBuffer, capacity); return nil }
}
