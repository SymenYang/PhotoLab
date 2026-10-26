import Foundation
import os
import RedlampEngineAPI
import simd
import Synchronization

/// The Adobe lens profiles (LCP files) photos are corrected with: those the user keeps in `Lens
/// Profiles` under Application Support/Redlamp (LNS-04), and from process 17 those Lightroom
/// Classic and Camera Raw install and the user's own Camera Raw profiles, read where they are and
/// never copied (LNS-16, DEC-85). Each folder is listed when a photo opens and a file is read again
/// only when its modification date changes; a missing folder holds none. Camera Raw's folders hold
/// over a thousand files, so they're listed again only when one of their folders changes, and a
/// file there is read whole only once its first sub-profile shows it may be the photo's.
public final class LCPProfileLibrary: Sendable {
    /// A folder of lens profiles, and whose.
    public struct Folder: Sendable, Hashable {
        public var url: URL
        public var kind: LensProfileFolder

        public init(url: URL, kind: LensProfileFolder) {
            self.url = url
            self.kind = kind
        }
    }

    /// The user's profiles, which photos open with.
    public static let user = LCPProfileLibrary(folders: [
        Folder(url: defaultDirectory, kind: .redlamp),
        Folder(url: cameraRawUserDirectory, kind: .cameraRawUser),
        Folder(url: cameraRawDirectory, kind: .cameraRaw),
    ])

    public static var defaultDirectory: URL {
        applicationSupport.appending(path: "Redlamp/Lens Profiles", directoryHint: .isDirectory)
    }

    /// The user's own Camera Raw lens profiles, where Adobe's Lens Profile Creator saves them.
    public static var cameraRawUserDirectory: URL {
        applicationSupport.appending(path: "Adobe/CameraRaw/LensProfiles", directoryHint: .isDirectory)
    }

    /// The lens profiles Lightroom Classic and Camera Raw install, a folder for each maker.
    public static let cameraRawDirectory = URL(
        fileURLWithPath: "/Library/Application Support/Adobe/CameraRaw/LensProfiles/1.0", isDirectory: true,
    )

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    /// The first process version that matches a profile made on another body than the photo's, one
    /// in Camera Raw's folders, or a fisheye profile (LNS-14, LNS-16, LNS-17).
    public static let widerMatchingProcess = 17

    /// Larger files aren't lens profiles.
    static let largestFile = 32 << 20
    /// The bytes read for a file's first sub-profile, which takes a few kilobytes.
    static let firstBytes = 64 << 10

    private struct File {
        var folder: LensProfileFolder
        var modified: Date
        var size: Int
        /// The whole profile once read, else its first sub-profile alone.
        var profile: LCPProfile? {
            didSet {
                lensKeys = first.map { first in
                    ([first.lens, first.lensPrettyName].compactMap(\.self) + first.alternateLensNames)
                        .map { LCPProfile.SubProfile.key($0) }
                } ?? []
            }
        }

        var complete: Bool
        var issues: [String]
        /// The first sub-profile's lens names as `LCPProfile.SubProfile.key` writes them.
        var lensKeys: [String] = []

        /// The first sub-profile, which names the camera and lens every other does.
        var first: LCPProfile.SubProfile? {
            profile?.subProfiles.first
        }
    }

    /// A folder's files and every folder inside it, with their modification dates.
    private struct Listing {
        var folders: [URL: Date]
        var files: [(url: URL, modified: Date, size: Int)]
    }

    public let folders: [Folder]
    private let files = Mutex<[URL: File]>([:])
    private let listings = Mutex<[URL: Listing]>([:])

    /// Redlamp's Lens Profiles folder.
    public var directory: URL {
        folders.first { $0.kind == .redlamp }?.url ?? folders[0].url
    }

    public init(folders: [Folder]) {
        precondition(!folders.isEmpty, "a library needs a folder")
        self.folders = folders
    }

    /// A library of Redlamp's Lens Profiles folder alone.
    public convenience init(directory: URL) {
        self.init(folders: [Folder(url: directory, kind: .redlamp)])
    }

    /// Reads every folder's files as far as matching first needs them, so the first photo opened
    /// doesn't wait for Camera Raw's thousand-odd files (a third of a second on an M4 Max).
    public func prepare() {
        _ = firstSubProfiles()
    }

    /// Files in Redlamp's Lens Profiles folder that couldn't be read, or whose sub-profiles were
    /// left out, with the reasons, as of the last listing.
    public var issues: [URL: [String]] {
        files.withLock { files in
            files.compactMapValues { $0.folder == .redlamp && !$0.issues.isEmpty ? $0.issues : nil }
        }
    }

    /// The correction for a raw photo from the profile for its camera and lens. Every process from 5
    /// takes a rectilinear profile made on the photo's own body, in Redlamp's folder: one whose lens
    /// name is the one the file reports, else one whose display name is, the first by path among
    /// equals. Where there's none, process 17 looks further (`acrossBodies`), fisheye profiles
    /// included, and the correction says so in its `profileProcess`. Nil when nothing matches.
    public func correction(for info: ImageInfo, sensorSize: PixelSize, orientation: Int) -> LensCorrection? {
        if var correction = ownBody(for: info, sensorSize: sensorSize, orientation: orientation) {
            correction.profileFolder = .redlamp
            return correction
        }
        var wider = acrossBodies(for: info, sensorSize: sensorSize, orientation: orientation)
        wider?.profileProcess = Self.widerMatchingProcess
        return wider
    }

    /// The match every process makes, as LNS-04 made it, which read no fisheye profiles.
    private func ownBody(for info: ImageInfo, sensorSize: PixelSize, orientation: Int) -> LensCorrection? {
        guard let make = info.make, let lens = info.lens else { return nil }
        let matches = profiles(in: [.redlamp]).map { url, profile in
            let camera = profile.subProfiles.filter {
                $0.isRaw && !$0.isFisheye && $0.matchesCamera(make: make, model: info.model)
            }
            let match = camera.map { $0.lensMatch(lens, make: make) }.max() ?? .unmatched
            return (url: url, match: match, subProfiles: camera.filter { $0.lensMatch(lens, make: make) == match })
        }
        for wanted in [LCPProfile.SubProfile.LensMatch.lens, .prettyName] {
            for candidate in matches where candidate.match == wanted {
                if var correction = LCPProfile.correction(
                    candidate.subProfiles, focalLength: info.focalLength, aperture: info.aperture, size: sensorSize,
                    orientation: orientation,
                ) {
                    correction.profileFileName = candidate.url.lastPathComponent
                    return correction
                }
            }
        }
        return nil
    }

    /// The correction for a raw photo from the profile an edit names (LNS-15), found by its file's
    /// name, whatever its case, or by its name where the choice gives no file name, the folders in
    /// order. Custom takes it whatever lens it was made for; Default and Auto only where it's of the
    /// photo's lens. Made on another body, or for another frame, it's scaled as process 17 scales
    /// a profile. Nil where it isn't on this Mac or can't fit the photo.
    public func correction(
        named choice: LensProfileChoice, for info: ImageInfo, sensorSize: PixelSize, orientation: Int,
    ) -> LensCorrection? {
        guard choice.namesProfile, let photo = PhotoIdentity(info, requiringLens: false) else { return nil }
        let order = folders.map(\.kind)
        let named = firstSubProfiles().filter { file in
            if let fileName = choice.fileName {
                return file.url.lastPathComponent.caseInsensitiveCompare(fileName) == .orderedSame
            }
            return file.first?.profileName == choice.name
        }.sorted { a, b in
            let (folderA, folderB) = (order.firstIndex(of: a.folder) ?? 0, order.firstIndex(of: b.folder) ?? 0)
            return folderA != folderB ? folderA < folderB : a.url.path < b.url.path
        }
        for file in named {
            guard let profile = wholeProfile(file.url) else { continue }
            let subProfiles = profile.subProfiles.filter(\.isRaw)
            guard let first = subProfiles.first,
                  choice.setup == .custom || photo.lensMatch(first, identified: nil) != nil,
                  var correction = fitted(
                      subProfiles,
                      body: photo.body(first),
                      info: info,
                      size: sensorSize,
                      orientation: orientation,
                  )
            else { continue }
            correction.profileFolder = file.folder
            correction.profileFileName = file.url.lastPathComponent
            if photo.body(first) != .own {
                correction.profileCamera = first.cameraPrettyName ?? first.model ?? first.make
            }
            return correction
        }
        return nil
    }

    /// The lens profiles a photographer can choose for a raw photo by hand (LNS-15): every folder's
    /// profiles made for raws on the photo's own body or on a sensor at least as large as its sensor,
    /// within a tenth, by make, model and name. Without the photo's crop factor, only those made on
    /// its own body, which can apply without being scaled. An edit names a profile by its file's
    /// name, so of files of one name only the first that can be used is listed, as it's the one used.
    public func options(for info: ImageInfo) -> [LensProfileOption] {
        guard let photo = PhotoIdentity(info, requiringLens: false) else { return [] }
        let order = folders.map(\.kind)
        let usable = firstSubProfiles().sorted { a, b in
            let (folderA, folderB) = (order.firstIndex(of: a.folder) ?? 0, order.firstIndex(of: b.folder) ?? 0)
            return folderA != folderB ? folderA < folderB : a.url.path < b.url.path
        }.compactMap { file -> LensProfileOption? in
            guard let first = file.first, first.isRaw else { return nil }
            if photo.body(first) != .own {
                guard let crop = info.cropFactor, let factor = first.sensorFormatFactor, factor <= crop * 1.1 else {
                    return nil
                }
            }
            let fileName = file.url.lastPathComponent
            let model = first.lensPrettyName ?? first.lens ?? file.url.deletingPathExtension().lastPathComponent
            return LensProfileOption(
                make: model.split(separator: " ").first.map(String.init) ?? model, model: model,
                name: first.profileName ?? model, fileName: fileName, folder: file.folder,
            )
        }
        var seen = Set<String>()
        return usable.filter { seen.insert($0.fileName.lowercased()).inserted }.sorted { a, b in
            for (x, y) in [(a.make, b.make), (a.model, b.model), (a.name, b.name)] {
                let order = x.localizedStandardCompare(y)
                if order != .orderedSame {
                    return order == .orderedAscending
                }
            }
            let (folderA, folderB) = (order.firstIndex(of: a.folder) ?? 0, order.firstIndex(of: b.folder) ?? 0)
            return folderA != folderB ? folderA < folderB : a.fileName < b.fileName
        }
    }

    /// A profile's correction for a photo: as recorded on its own body where the frame fits, else
    /// scaled to the photo's frame where its sensor covers the photo's within a tenth.
    private func fitted(
        _ subProfiles: [LCPProfile.SubProfile], body: PhotoIdentity.Body?, info: ImageInfo, size sensorSize: PixelSize,
        orientation: Int,
    ) -> LensCorrection? {
        if body == .own, let correction = LCPProfile.correction(
            subProfiles, focalLength: info.focalLength, aperture: info.aperture, size: sensorSize,
            orientation: orientation,
        ) {
            return correction
        }
        let size = SIMD2(Double(sensorSize.width), Double(sensorSize.height))
        guard let first = subProfiles.first, let crop = info.cropFactor, let factor = first.sensorFormatFactor,
              factor <= crop * 1.1, let ratio = first.ratio(toCropFactor: crop, size: size)
        else { return nil }
        return LCPProfile.correction(
            subProfiles, focalLength: info.focalLength, aperture: info.aperture, size: sensorSize,
            orientation: orientation, fit: .scaled(ratio),
        )
    }

    /// Process 17's match, from every folder: a profile of the photo's lens made on its own body,
    /// else on another body of its make, else on a body of a make sharing its mount, the folders in
    /// order and the first by path among equals; one made on another body only where its sensor is
    /// at least as large as the photo's, give or take a tenth (APS-C's sizes differ by that much),
    /// its models scaled to the photo's sensor. The lens is the one the file names, or one of the
    /// lens's other names, else, where the file names none, the one its maker's number identifies.
    private func acrossBodies(for info: ImageInfo, sensorSize: PixelSize, orientation: Int) -> LensCorrection? {
        guard let photo = PhotoIdentity(info) else { return nil }
        let listed = firstSubProfiles()
        let identified = photo.lens == nil ? identifiedLens(photo, among: listed) : nil
        let folderOrder = folders.map(\.kind)
        let candidates = listed.compactMap { file -> Candidate? in
            guard photo.mayName(file.lensKeys) || photo.lens == nil && file.first?.lensID == photo.lensID,
                  let first = file.first, first.isRaw, let body = photo.body(first),
                  let lens = photo.lensMatch(first, identified: identified)
            else { return nil }
            return Candidate(url: file.url, folder: file.folder, body: body, lens: lens)
        }.sorted { a, b in
            let (folderA, folderB) = (
                folderOrder.firstIndex(of: a.folder) ?? 0,
                folderOrder.firstIndex(of: b.folder) ?? 0,
            )
            if a.body != b.body {
                return a.body < b.body
            }
            if folderA != folderB {
                return folderA < folderB
            }
            if a.lens != b.lens {
                return a.lens > b.lens
            }
            return a.url.path < b.url.path
        }
        for candidate in candidates {
            guard let profile = wholeProfile(candidate.url) else { continue }
            let subProfiles = profile.subProfiles.filter { subProfile in
                subProfile.isRaw && photo.body(subProfile) == candidate.body
                    && photo.lensMatch(subProfile, identified: identified) == candidate.lens
            }
            guard let first = subProfiles.first,
                  var correction = fitted(
                      subProfiles,
                      body: candidate.body,
                      info: info,
                      size: sensorSize,
                      orientation: orientation,
                  )
            else { continue }
            correction.profileFolder = candidate.folder
            correction.profileFileName = candidate.url.lastPathComponent
            if candidate.body != .own {
                correction.profileCamera = first.cameraPrettyName ?? first.model ?? first.make
            }
            return correction
        }
        return nil
    }

    private struct Candidate {
        var url: URL
        var folder: LensProfileFolder
        var body: PhotoIdentity.Body
        var lens: LCPProfile.SubProfile.LensMatch
    }

    /// The lens a photo whose file names none was taken with, by the number its maker gives the lens:
    /// the one lens the profiles of the photo's maker carrying that number describe, among those
    /// whose focal lengths agree with the lens's, or with the photo's where the lens's aren't known.
    /// Nil where none or several do: makers' numbers aren't unique (Nikon's 165 is the 105 mm f/1.4E
    /// and the 35 mm f/1.8G alike), and the lens is then chosen by hand.
    private func identifiedLens(_ photo: PhotoIdentity, among listed: [Listed]) -> String? {
        guard let id = photo.lensID else { return nil }
        var lenses = Set<String>()
        for file in listed {
            guard let first = file.first, first.lensID == id, photo.makes.contains(PhotoIdentity.makeKey(of: first))
            else { continue }
            let range = first.lensFocalRange ?? wholeProfile(file.url).flatMap { profile in
                let focalLengths = profile.subProfiles.map(\.focalLength)
                return focalLengths.min().flatMap { shortest in focalLengths.max().map { shortest ... $0 } }
            }
            guard let range, photo.agrees(with: range) else { continue }
            lenses.insert(PhotoIdentity.lensKey(of: first))
        }
        return lenses.count == 1 ? lenses.first : nil
    }

    // MARK: - Files

    /// Every profile in Redlamp's folders, read whole, by path, read again where its file changed.
    func profiles(in kinds: Set<LensProfileFolder> = [.redlamp]) -> [(url: URL, profile: LCPProfile)] {
        let listed = folders.filter { kinds.contains($0.kind) }.flatMap { folder in
            listing(of: folder).map { (folder: folder.kind, file: $0) }
        }
        let kept = Set(listed.map(\.file.url))
        return files.withLock { files in
            files = files.filter { url, file in !kinds.contains(file.folder) || kept.contains(url) }
            return listed.compactMap { folder, listed in
                if files[listed.url]?.modified != listed.modified || files[listed.url]?.complete != true {
                    files[listed.url] = Self.read(
                        listed.url,
                        folder: folder,
                        modified: listed.modified,
                        size: listed.size,
                    )
                }
                return files[listed.url]?.profile.map { (listed.url, $0) }
            }
        }
    }

    /// A file as process 17 first looks at it: its first sub-profile, and its lens's names as keys.
    private struct Listed {
        var url: URL
        var folder: LensProfileFolder
        var first: LCPProfile.SubProfile?
        var lensKeys: [String]
    }

    /// Every file of every folder, with its first sub-profile, read again where its file changed.
    /// Redlamp's folder is read whole, as `profiles` reads it.
    private func firstSubProfiles() -> [Listed] {
        _ = profiles(in: [.redlamp])
        let others = folders.filter { $0.kind != .redlamp }.flatMap { folder in
            listing(of: folder).map { (folder: folder.kind, file: $0) }
        }
        return files.withLock { files in
            let kept = Set(others.map(\.file.url))
            files = files.filter { $0.value.folder == .redlamp || kept.contains($0.key) }
            for (folder, listed) in others where files[listed.url]?.modified != listed.modified {
                files[listed.url] = Self.read(
                    listed.url, folder: folder, modified: listed.modified, size: listed.size, firstOnly: true,
                )
            }
            return files.map { Listed(
                url: $0.key,
                folder: $0.value.folder,
                first: $0.value.first,
                lensKeys: $0.value.lensKeys,
            ) }
        }
    }

    /// A listed file's whole profile, read now if only its first sub-profile was.
    private func wholeProfile(_ url: URL) -> LCPProfile? {
        files.withLock { files in
            guard var file = files[url] else { return nil }
            if !file.complete {
                file = Self.read(url, folder: file.folder, modified: file.modified, size: file.size)
                files[url] = file
            }
            return file.profile
        }
    }

    /// A folder's LCP files with their modification dates and sizes, by path. Redlamp's folder is
    /// listed every time; another is listed again only when a folder in it has changed, as adding,
    /// removing or replacing a file changes its folder's date.
    private func listing(of folder: Folder) -> [(url: URL, modified: Date, size: Int)] {
        if folder.kind != .redlamp, let listed = listings.withLock({ $0[folder.url] }),
           listed.folders.allSatisfy({ url, modified in Self.modified(url) == modified }) {
            return listed.files
        }
        let listed = Self.list(folder.url)
        if folder.kind != .redlamp {
            listings.withLock { $0[folder.url] = listed }
        }
        return listed.files
    }

    /// Read afresh: a URL keeps the resource values it has read.
    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static func list(_ directory: URL) -> Listing {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        var listing = Listing(folders: [:], files: [])
        guard let root = modified(directory) else { return listing }
        listing.folders[directory] = root
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true },
        ) else { return listing }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), let date = values.contentModificationDate
            else { continue }
            if values.isDirectory == true {
                listing.folders[url] = modified(url) ?? date
            } else if values.isRegularFile == true, url.pathExtension.lowercased() == "lcp" {
                listing.files.append((url, date, values.fileSize ?? 0))
            }
        }
        listing.files.sort { $0.url.path < $1.url.path }
        return listing
    }

    private static func read(
        _ url: URL, folder: LensProfileFolder, modified: Date, size: Int, firstOnly: Bool = false,
    ) -> File {
        var file = File(folder: folder, modified: modified, size: size, profile: nil, complete: !firstOnly, issues: [])
        if size > largestFile {
            file.issues = ["larger than a lens profile can be"]
            file.complete = true
        } else {
            do {
                let data = try firstOnly && size > firstBytes ? head(of: url) : Data(contentsOf: url)
                let profile = try LCPProfile(data: data, firstOnly: firstOnly)
                file.profile = profile
                file.issues = profile.skipped
            } catch {
                file.issues = ["\(error)"]
                file.complete = true
            }
        }
        if !file.issues.isEmpty, file.complete || file.profile?.subProfiles.isEmpty == true {
            Logger(subsystem: "app.redlamp.services", category: "lens-profiles").notice(
                "\(url.lastPathComponent, privacy: .public): \(file.issues.joined(separator: "; "), privacy: .public)",
            )
        }
        return file
    }

    /// A file's first bytes, enough for its first sub-profile; the whole file where the first
    /// sub-profile doesn't end within them.
    private static func head(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: firstBytes) ?? Data()
        return data.range(of: Data("</rdf:li>".utf8)) == nil ? try Data(contentsOf: url) : data
    }
}

/// A photo's camera and lens as lens profiles match them (LNS-14).
private struct PhotoIdentity {
    /// How near a profile's camera is to the photo's: its own body, another of its make, or a
    /// make sharing its mount.
    enum Body: Int, Comparable {
        case own, make, mount

        static func < (a: Body, b: Body) -> Bool {
            a.rawValue < b.rawValue
        }
    }

    /// The makes that share a mount, by `makeKey`: L-mount, and Micro Four Thirds.
    static let mounts: [Set<String>] = [["leica", "panasonic", "sigma"], ["olympus", "panasonic"]]

    /// The photo's make and model as its file and as LibRaw's camera list name them.
    let cameras: [(make: String, model: String?)]
    let makes: Set<String>
    let lens: String?
    let lensID: Int?
    let focalLength: Double?
    let lensFocalRange: ClosedRange<Double>?
    /// The lens's name as a key, with each of the photo's makes left off its start: a profile's
    /// lens name can match only if its key ends with one.
    let lensKeys: [String]

    /// Nil without the photo's make, and, `requiringLens`, without its lens's name or number.
    init?(_ info: ImageInfo, requiringLens: Bool = true) {
        guard let make = info.make else { return nil }
        let cameras = [(make: make, model: info.model)]
            + (info.canonicalMake.map { [(make: $0, model: info.canonicalModel ?? info.model)] } ?? [])
        let makes = Set(cameras.map { Self.makeKey($0.make) })
        let lens = info.lens.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        guard !requiringLens || lens != nil || info.lensID != nil else { return nil }
        self.cameras = cameras
        self.makes = makes
        self.lens = lens
        lensID = info.lensID
        focalLength = info.focalLength
        lensFocalRange = info.lensFocalRange
        let dropped = makes.union(cameras.map { LCPProfile.SubProfile.makeKey($0.make) })
        lensKeys = lens.map { lens in
            Array(Set([LCPProfile.SubProfile.key(lens)] + dropped
                    .map { LCPProfile.SubProfile.key(lens, dropping: [$0]) }))
                .filter { !$0.isEmpty }
        } ?? []
    }

    /// Whether a profile whose lens names have these keys may be of the photo's lens, before
    /// `lensMatch` decides: `key` leaves off only a make at a name's start.
    func mayName(_ keys: [String]) -> Bool {
        keys.contains { key in lensKeys.contains { key.hasSuffix($0) } }
    }

    func body(_ subProfile: LCPProfile.SubProfile) -> Body? {
        if cameras.contains(where: { subProfile.matchesCamera(make: $0.make, model: $0.model) }) {
            return .own
        }
        let theirs = Self.makeKey(of: subProfile)
        if makes.contains(theirs) {
            return .make
        }
        return Self.mounts.contains { $0.contains(theirs) && !$0.isDisjoint(with: makes) } ? .mount : nil
    }

    /// How the photo's lens matches a sub-profile's: by the name the reference photos' metadata
    /// gives it, by the profile's display name, by another name the lens goes by, or by the maker's
    /// number where the file names no lens (`identified`).
    func lensMatch(_ subProfile: LCPProfile.SubProfile, identified: String?) -> LCPProfile.SubProfile.LensMatch? {
        guard let lens else {
            return identified.map { $0 == Self.lensKey(of: subProfile) && subProfile.lensID == lensID } == true
                ? .lensID : nil
        }
        let match = cameras.map { subProfile.lensMatch(lens, make: $0.make) }.max() ?? .unmatched
        if match != .unmatched {
            return match
        }
        let wanted = LCPProfile.SubProfile.key(lens, dropping: Array(makes))
        let alternates = subProfile.alternateLensNames.map { LCPProfile.SubProfile.key($0, dropping: Array(makes)) }
        return !wanted.isEmpty && alternates.contains(wanted) ? .alternate : nil
    }

    /// Whether a profile's lens, of `range` millimetres, can be the photo's: the same focal
    /// lengths as the lens's within 3%, or, where the lens's aren't known, the photo's among them.
    func agrees(with range: ClosedRange<Double>) -> Bool {
        if let lensFocalRange {
            return abs(range.lowerBound / lensFocalRange.lowerBound - 1) <= 0.03
                && abs(range.upperBound / lensFocalRange.upperBound - 1) <= 0.03
        }
        guard let focalLength else { return false }
        return focalLength >= range.lowerBound * 0.97 && focalLength <= range.upperBound * 1.03
    }

    /// A make as the tiers compare it: its first word, with OM Digital Solutions as the Olympus it
    /// continues, and Ricoh's and Asahi's names for Pentax bodies as Pentax.
    static func makeKey(_ make: String) -> String {
        let key = LCPProfile.SubProfile.makeKey(make)
        return switch key {
        case "om": "olympus"
        case "asahi": "pentax"
        default: key
        }
    }

    static func makeKey(of subProfile: LCPProfile.SubProfile) -> String {
        let key = makeKey(subProfile.make)
        let names = [subProfile.model, subProfile.uniqueCameraModel, subProfile.cameraPrettyName].compactMap(\.self)
        return key == "ricoh" && names.contains { $0.lowercased().contains("pentax") } ? "pentax" : key
    }

    /// A profile's lens for telling lenses apart: its metadata name, else its display name.
    static func lensKey(of subProfile: LCPProfile.SubProfile) -> String {
        LCPProfile.SubProfile.key(subProfile.lens ?? subProfile.lensPrettyName ?? subProfile.profileName ?? "")
    }
}
