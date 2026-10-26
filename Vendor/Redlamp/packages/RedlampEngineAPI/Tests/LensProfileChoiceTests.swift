import Foundation
import Testing
@testable import RedlampEngineAPI

/// The lens profile an edit names (LNS-15), as Lightroom stores it and as the sidecar keeps it.
struct LensProfileChoiceTests {
    static let canon = LensProfileChoice(
        setup: .custom, name: "Adobe (Canon EF 24-70mm f/2.8L II USM)",
        fileName: "Canon EOS 5D Mark III (Canon EF 24-70mm f2.8L II USM) - RAW.lcp",
    )

    @Test func `reads Lightroom's Setup, profile name and file name`() {
        let custom = LensProfileChoice(lightroomSetup: "Custom", name: Self.canon.name, fileName: Self.canon.fileName)
        #expect(custom == Self.canon)
        #expect(LensProfileChoice(lightroomSetup: "Auto", name: nil, fileName: nil) == LensProfileChoice(setup: .auto))
        #expect(LensProfileChoice(lightroomSetup: "LensDefaults", name: "", fileName: "") == nil)
        #expect(LensProfileChoice(lightroomSetup: nil, name: "Adobe (Lens)", fileName: nil)?.setup == .defaults)
        #expect(LensProfileChoice.Setup.allCases.map(\.lightroomName) == ["LensDefaults", "Auto", "Custom"])
    }

    @Test func `the edit keeps it, writes it and reads it back, and it counts as a change`() throws {
        var recipe = EditRecipe()
        #expect(recipe.isPristine)
        recipe.lensProfileChoice = Self.canon
        #expect(!recipe.isPristine)
        let read = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe))
        #expect(read.lensProfileChoice == Self.canon)
        let written = try #require(String(data: JSONEncoder().encode(EditRecipe()), encoding: .utf8))
        #expect(!written.contains("lensProfile\""), "an edit at Default writes none")
    }

    @Test func `choosing one turns the Lens Corrections panel back on`() {
        var recipe = EditRecipe()
        recipe.panelsOff = [.lens]
        recipe.lensProfileChoice = LensProfileChoice(setup: .auto)
        #expect(recipe.isOn(.lens))
    }

    @Test func `it travels with the profile corrections when settings are copied`() throws {
        var source = EditRecipe()
        source.lensProfileChoice = Self.canon
        let item = try #require(SettingsGroup.allItems.first { $0.id == "lens.profile" })
        #expect(item.fields == [.lensProfile])
        let pasted = EditRecipe().pasting(source, SettingsSelection(items: [item.id]))
        #expect(pasted.lensProfileChoice == Self.canon)
        #expect(source.pasting(EditRecipe(), SettingsSelection(items: [item.id])).lensProfileChoice == nil)
    }
}
