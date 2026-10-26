import Foundation
import Testing
@testable import RedlampMasking

struct CompiledModelsTests {
    private func folder(_ names: [String], modified: Date) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        for name in names {
            let model = url.appending(path: name)
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: model.path)
        }
        return url
    }

    private func remaining(_ url: URL) throws -> Set<String> {
        try Set(FileManager.default.contentsOfDirectory(atPath: url.path))
    }

    @Test func `an old compile of the model is removed, with or without its suffix`() throws {
        let now = Date()
        let url = try folder(
            ["Sam3ImageEncoder.mlmodelc", "Sam3ImageEncoder_0C594D8F-01A7-4B9F-A4E8-FB55CF2790E6.mlmodelc"],
            modified: now.addingTimeInterval(-2 * CompiledModels.leftoverAge),
        )
        defer { try? FileManager.default.removeItem(at: url) }
        CompiledModels.removeLeftovers(of: "Sam3ImageEncoder", in: url, now: now)
        #expect(try remaining(url).isEmpty)
    }

    @Test func `a recent compile may belong to a running launch and is kept`() throws {
        let now = Date()
        let url = try folder(["Sam3ImageEncoder_A.mlmodelc"], modified: now.addingTimeInterval(-60))
        defer { try? FileManager.default.removeItem(at: url) }
        CompiledModels.removeLeftovers(of: "Sam3ImageEncoder", in: url, now: now)
        #expect(try remaining(url) == ["Sam3ImageEncoder_A.mlmodelc"])
    }

    @Test func `other models and other files are kept`() throws {
        let now = Date()
        let names = ["Sam3TextDecoder_A.mlmodelc", "Sam3ImageEncoderLarge.mlmodelc", "Sam3ImageEncoder_A.mlpackage"]
        let url = try folder(names, modified: now.addingTimeInterval(-2 * CompiledModels.leftoverAge))
        defer { try? FileManager.default.removeItem(at: url) }
        CompiledModels.removeLeftovers(of: "Sam3ImageEncoder", in: url, now: now)
        #expect(try remaining(url) == Set(names))
    }

    /// A scratch folder holding `CompiledModels`, where `destination` is, beside compiles as
    /// `MLModel.compileModel` leaves them.
    private func scratch() throws -> (url: URL, destination: URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let root = url.appending(path: "CompiledModels")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (url, root.appending(path: "vitmatte-base-v1-ViTMatteBaseW8.mlmodelc"))
    }

    /// A compile in `folder`, its model file holding `marker`.
    private func compile(_ marker: String, in folder: URL) throws -> URL {
        let url = folder.appending(path: "ViTMatteBaseW8_\(UUID().uuidString).mlmodelc")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: url.appending(path: "model.mil"))
        return url
    }

    private func marker(_ compile: URL) throws -> String {
        try String(contentsOf: compile.appending(path: "model.mil"), encoding: .utf8)
    }

    @Test func `a compile takes its place, leaving nothing beside it`() throws {
        let (url, destination) = try scratch()
        defer { try? FileManager.default.removeItem(at: url) }
        let new = try compile("new", in: url)
        try CompiledModels.place(new, at: destination)
        #expect(try marker(destination) == "new")
        #expect(try remaining(destination.deletingLastPathComponent()) == [destination.lastPathComponent])
        #expect(!FileManager.default.fileExists(atPath: new.path))
    }

    @Test func `a compile another process put in place first stays, as it may be using it`() throws {
        let (url, destination) = try scratch()
        defer { try? FileManager.default.removeItem(at: url) }
        try CompiledModels.place(compile("first", in: url), at: destination)
        let second = try compile("second", in: url)
        try CompiledModels.place(second, at: destination)
        #expect(try marker(destination) == "first")
        #expect(try remaining(destination.deletingLastPathComponent()) == [destination.lastPathComponent])
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }

    @Test func `compiles placed side by side leave one whole compile in place`() async throws {
        let (url, destination) = try scratch()
        defer { try? FileManager.default.removeItem(at: url) }
        let compiles = try (0 ..< 8).map { try compile("\($0)", in: url) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for compile in compiles {
                group.addTask { try CompiledModels.place(compile, at: destination) }
            }
            try await group.waitForAll()
        }
        #expect(try (0 ..< 8).map(String.init).contains(marker(destination)))
        #expect(try remaining(destination.deletingLastPathComponent()) == [destination.lastPathComponent])
        #expect(compiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }
}
