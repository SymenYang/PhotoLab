import Foundation

/// The lens profile an edit names, as Lightroom's Lens Corrections panel chooses one (LNS-15): its
/// Setup and, where one was chosen by hand or brought across from Lightroom, the profile by name and
/// file name, as `crs:LensProfileName` and `crs:LensProfileFilename` store it. An edit without one
/// is at Default. Only names: the profile's models stay in its file, on the Mac (DEC-85).
public struct LensProfileChoice: Codable, Sendable, Hashable {
    public enum Setup: String, Codable, Sendable, CaseIterable {
        /// Lightroom's Default (`LensDefaults`): the profile matched to the photo's lens, as Auto,
        /// since Redlamp keeps no lens defaults of its own.
        case defaults
        /// The profile matched to the photo's lens.
        case auto
        /// The profile named here, whatever lens it was made for: an adapted or manual lens, or one
        /// the file doesn't name.
        case custom

        /// The menu's name for it.
        public var name: String {
            switch self {
            case .defaults: "Default"
            case .auto: "Auto"
            case .custom: "Custom"
            }
        }

        /// `crs:LensProfileSetup`'s value.
        public var lightroomName: String {
            switch self {
            case .defaults: "LensDefaults"
            case .auto: "Auto"
            case .custom: "Custom"
            }
        }

        public init?(lightroomName: String) {
            guard let setup = Self.allCases.first(where: { $0.lightroomName == lightroomName }) else { return nil }
            self = setup
        }
    }

    public var setup: Setup
    /// The profile's name, such as "Adobe (Canon EF 24-70mm f/2.8L II USM)".
    public var name: String?
    /// The name of the profile's file, such as "Canon EOS 5D Mark III (Canon EF 24-70mm f2.8L II USM) - RAW.lcp".
    public var fileName: String?

    public init(setup: Setup, name: String? = nil, fileName: String? = nil) {
        self.setup = setup
        self.name = name
        self.fileName = fileName
    }

    /// From a Lightroom edit's `crs:LensProfileSetup`, `LensProfileName` and `LensProfileFilename`;
    /// nil for Default without a named profile, which an edit without a choice is.
    public init?(lightroomSetup: String?, name: String?, fileName: String?) {
        let setup = lightroomSetup.flatMap(Setup.init(lightroomName:)) ?? .defaults
        let name = name.flatMap { $0.isEmpty ? nil : $0 }
        let fileName = fileName.flatMap { $0.isEmpty ? nil : $0 }
        guard setup != .defaults || name != nil || fileName != nil else { return nil }
        self.init(setup: setup, name: name, fileName: fileName)
    }

    /// Whether the choice names a profile.
    public var namesProfile: Bool {
        name != nil || fileName != nil
    }
}

/// A lens profile on this Mac a photographer can choose for a photo (LNS-15), as Lightroom's Make,
/// Model and Profile menus list it.
public struct LensProfileOption: Codable, Sendable, Hashable {
    /// The lens's maker, the first word of its display name.
    public var make: String
    /// The lens's display name.
    public var model: String
    /// The profile's name.
    public var name: String
    public var fileName: String
    public var folder: LensProfileFolder

    public init(make: String, model: String, name: String, fileName: String, folder: LensProfileFolder) {
        self.make = make
        self.model = model
        self.name = name
        self.fileName = fileName
        self.folder = folder
    }

    /// The choice that names this profile.
    public var choice: LensProfileChoice {
        LensProfileChoice(setup: .custom, name: name, fileName: fileName)
    }
}
