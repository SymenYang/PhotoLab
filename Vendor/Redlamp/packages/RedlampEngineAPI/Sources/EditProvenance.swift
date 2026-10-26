import Foundation

/// Where an edit converted from another app's develop settings came from (EDT-23, EDT-12): the file it was
/// read from, the photo in it, when, and the settings that were carried over approximately or left out, by
/// name. Provenance only: rendering never reads it.
public struct EditProvenance: Codable, Sendable, Hashable {
    /// What the settings were read from. A name a newer Redlamp wrote is kept.
    public struct Source: RawRepresentable, Codable, Sendable, Hashable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// A Lightroom Classic catalog (`.lrcat`).
        public static let lightroomCatalog = Source(rawValue: "lightroomCatalog")
        /// An XMP sidecar beside the photo, written by Lightroom, Camera Raw or Bridge.
        public static let xmpSidecar = Source(rawValue: "xmpSidecar")
        /// XMP inside the photo's own file.
        public static let embeddedXMP = Source(rawValue: "embeddedXMP")
    }

    public var source: Source
    /// The catalog's path, or the XMP's: the sidecar's, or the photo's own for embedded XMP.
    public var path: String
    /// The photo or virtual copy in the catalog (`Adobe_images.id_local`).
    public var photo: Int64?
    /// The settings' digest in the catalog (`Adobe_imageDevelopSettings.digest`), which tells whether they
    /// changed since.
    public var digest: String?
    /// When the settings were converted.
    public var date: Date
    /// The settings carried over approximately and those left out, by their Camera Raw names.
    public var approximated: [String]
    public var leftOut: [String]
    /// Fields written by a newer Redlamp, written back unchanged.
    public var unknownFields: [String: JSONValue] = [:]

    public init(
        source: Source, path: String, photo: Int64? = nil, digest: String? = nil, date: Date,
        approximated: [String] = [], leftOut: [String] = [],
    ) {
        self.source = source
        self.path = path
        self.photo = photo
        self.digest = digest
        self.date = date
        self.approximated = approximated
        self.leftOut = leftOut
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case source, path, photo, digest, date, approximated, leftOut
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(Source.self, forKey: .source)
        path = try container.decode(String.self, forKey: .path)
        photo = try container.decodeIfPresent(Int64.self, forKey: .photo)
        digest = try container.decodeIfPresent(String.self, forKey: .digest)
        date = try container.decode(Date.self, forKey: .date)
        approximated = try container.decodeIfPresent([String].self, forKey: .approximated) ?? []
        leftOut = try container.decodeIfPresent([String].self, forKey: .leftOut) ?? []
        unknownFields = try decoder.container(keyedBy: DynamicCodingKey.self)
            .unknownFields(excluding: Set(CodingKeys.allCases.map(\.stringValue)))
    }

    public func encode(to encoder: Encoder) throws {
        var unknown = encoder.container(keyedBy: DynamicCodingKey.self)
        try unknown.encode(unknownFields)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(photo, forKey: .photo)
        try container.encodeIfPresent(digest, forKey: .digest)
        try container.encode(date, forKey: .date)
        if !approximated.isEmpty {
            try container.encode(approximated, forKey: .approximated)
        }
        if !leftOut.isEmpty {
            try container.encode(leftOut, forKey: .leftOut)
        }
    }
}
