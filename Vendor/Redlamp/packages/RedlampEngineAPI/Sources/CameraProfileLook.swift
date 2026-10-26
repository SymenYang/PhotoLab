import Foundation

public extension BaseLookReference {
    /// The id prefix of looks from the photographer's own Adobe camera profiles (TON-51, TON-52):
    /// `local/adobe/<profile>` for a `.dcp`, `local/adobe/<profile>/<look>` for an XMP look over it,
    /// each a hash of what renders.
    static let adobeIDPrefix = "local/adobe/"

    /// Whether the look is one of the photographer's Adobe camera profiles, which render only on a
    /// Mac that has the profile (DEC-85).
    var isAdobeProfile: Bool {
        id.hasPrefix(Self.adobeIDPrefix)
    }

    /// The Redlamp look that renders in place of an Adobe profile that isn't on this Mac.
    var adobeStandIn: BuiltInBaseLook? {
        isAdobeProfile ? AdobeProfileStandIn.look(forProfileNamed: name) : nil
    }

    /// What names an Adobe look apart from the camera whose profile it was chosen over: an XMP
    /// look's hash, a `.dcp`'s name. A photo from another camera renders the look over its own
    /// camera's profile of the same key, as Lightroom does when settings are synced across cameras.
    var adobeLookKey: String? {
        guard isAdobeProfile else { return nil }
        let parts = id.dropFirst(Self.adobeIDPrefix.count).split(separator: "/")
        return parts.count == 2 ? "look/\(parts[1])@\(version)" : "profile/\(name)@\(version)"
    }

    /// Whether `other` is the same Adobe look, perhaps over another camera's profile.
    func isSameAdobeLook(as other: BaseLookReference) -> Bool {
        isSameLook(as: other) || (adobeLookKey != nil && adobeLookKey == other.adobeLookKey)
    }
}

/// One of the photographer's Adobe camera profiles that can render the open photo, as the Base
/// Look menu lists it (TON-51, TON-52).
public struct CameraProfileLook: Sendable, Hashable, Identifiable {
    /// Lightroom's groups for them, in the menu's order.
    public enum Group: Sendable, Hashable {
        /// Adobe Standard and the six Adobe Raw looks over it.
        case adobeRaw
        /// The camera's Camera Matching profiles.
        case cameraMatching
        /// Adobe's creative looks, in Lightroom's groups (Artistic, B&W, Modern, Vintage).
        case creative(String)
        /// The photographer's own, in their group when they have one.
        case own(String?)
    }

    public var reference: BaseLookReference
    public var group: Group
    /// Where it came from, and what of it Redlamp leaves out, for the menu's help.
    public var summary: String
    public var isMonochrome: Bool
    /// The develop settings an XMP look carries besides its tables, which Redlamp leaves out
    /// (`Clarity +8`).
    public var leftOut: [String]

    public var id: String {
        reference.id
    }

    public init(
        reference: BaseLookReference,
        group: Group,
        summary: String,
        isMonochrome: Bool = false,
        leftOut: [String] = [],
    ) {
        self.reference = reference
        self.group = group
        self.summary = summary
        self.isMonochrome = isMonochrome
        self.leftOut = leftOut
    }
}

/// The Redlamp look that stands in for an Adobe profile where it isn't on the Mac (DEC-85), by
/// name, as the Lightroom edits design maps Lightroom's profiles: each Adobe Raw look to Redlamp's
/// of that name, Adobe Standard to Color, and other profiles by the words in their names.
public enum AdobeProfileStandIn {
    /// Adobe's six Adobe Raw looks, each with Redlamp's look of the same name.
    public static let adobeRawLooks: [String: BuiltInBaseLook] = [
        "Adobe Color": .color, "Adobe Vivid": .vivid, "Adobe Portrait": .portrait, "Adobe Landscape": .landscape,
        "Adobe Neutral": .neutral, "Adobe Monochrome": .monochrome,
    ]

    public static func look(forProfileNamed name: String) -> BuiltInBaseLook {
        if let look = adobeRawLooks[name] {
            return look
        }
        let words = name.lowercased()
        let kinds: [(BuiltInBaseLook, [String])] = [
            (.monochrome, ["monochrome", "b&w", "black", "acros", "grayscale", "greyscale"]),
            (.neutral, ["neutral", "flat", "faithful", "eterna"]),
            (.vivid, ["vivid", "velvia", "vibrant"]),
            (.portrait, ["portrait", "astia", "soft", "pro neg"]),
            (.landscape, ["landscape"]),
        ]
        let tokens = Set(words.split { !$0.isLetter && $0 != "&" }.map(String.init))
        for (look, names) in kinds
            where names.contains(where: { $0.contains(" ") ? words.contains($0) : tokens.contains($0) }) {
            return look
        }
        return .color
    }
}
