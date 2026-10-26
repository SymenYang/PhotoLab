import Foundation
import os
import RedlampEngineAPI
import Synchronization

/// The Adobe camera profiles on this Mac (TON-51, TON-52), each read where it is and never copied
/// (DEC-85): Camera Raw's own, which Lightroom Classic and Camera Raw install, the photographer's
/// Camera Raw folder, and files the photographer chose. Folders are listed when a photo's profiles
/// are asked for; a file is read again only when its modification date changes, and in Camera
/// Raw's own folder, only a file whose name is the photo's camera.
public final class CameraProfileLibrary: Sendable {
    /// Where profiles are looked for.
    public struct Locations: Sendable, Hashable {
        /// Camera Raw's folder: `CameraProfiles/Adobe Standard`, `CameraProfiles/Camera/<camera>` and
        /// the looks under `Settings/Adobe/Profiles`.
        public var cameraRaw: URL?
        /// The photographer's Camera Raw folder: `CameraProfiles` and `Settings`.
        public var userCameraRaw: URL?
        /// `.dcp` and `.xmp` files, or folders of them, the photographer chose.
        public var chosen: [URL]

        public init(cameraRaw: URL?, userCameraRaw: URL?, chosen: [URL] = []) {
            self.cameraRaw = cameraRaw
            self.userCameraRaw = userCameraRaw
            self.chosen = chosen
        }

        /// Where Lightroom Classic and Camera Raw keep them on a Mac.
        public static var standard: Locations {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Locations(
                cameraRaw: URL(fileURLWithPath: "/Library/Application Support/Adobe/CameraRaw", isDirectory: true),
                userCameraRaw: home.appending(
                    path: "Library/Application Support/Adobe/CameraRaw",
                    directoryHint: .isDirectory,
                ),
            )
        }
    }

    /// Where a profile was found, which the Base Look menu groups by.
    public enum Source: String, Sendable, Hashable, CaseIterable {
        /// Adobe Standard, and the six Adobe Raw looks over it.
        case adobeRaw
        /// The camera's Camera Matching profiles, and looks made for one camera.
        case cameraMatching
        /// Adobe's creative looks.
        case creative
        /// The photographer's own, and the files they chose.
        case own
    }

    public struct Profile: Sendable, Hashable {
        public var url: URL
        public var source: Source
        public var dcp: DCPProfile
    }

    public struct Look: Sendable, Hashable {
        public var url: URL
        public var source: Source
        public var look: AdobeLook
    }

    /// A camera's profiles and the looks that may go over them, each once, in the order the menu
    /// lists them.
    public struct Found: Sendable, Hashable {
        public var profiles: [Profile] = []
        public var looks: [Look] = []

        /// The camera profile a look goes over: the one it names, else Adobe Standard.
        public func base(for look: AdobeLook) -> Profile? {
            let name = look.baseProfile ?? "Adobe Standard"
            return profiles.first { $0.dcp.name == name && $0.source != .own }
                ?? profiles.first { $0.dcp.name == name }
        }
    }

    /// The names of Adobe's six Adobe Raw looks.
    public static let adobeRawLooks = Set(AdobeProfileStandIn.adobeRawLooks.keys)

    /// The photographer's profiles, which photos open with.
    public static let user = CameraProfileLibrary(locations: .standard)

    private struct File {
        var modified: Date
        var dcp: DCPProfile?
        var look: AdobeLook?
        var issue: String?
    }

    private let locations: Mutex<Locations>
    private let files = Mutex<[URL: File]>([:])

    public init(locations: Locations) {
        self.locations = Mutex(locations)
    }

    public var currentLocations: Locations {
        locations.withLock { $0 }
    }

    /// Moves when the chosen files change, so what was found before can be found again.
    public var revision: Int {
        revisions.withLock { $0 }
    }

    private let revisions = Mutex(0)

    /// The files the photographer chose, replacing the last ones.
    public func setChosen(_ urls: [URL]) {
        locations.withLock { $0.chosen = urls }
        revisions.withLock { $0 += 1 }
    }

    /// Files that couldn't be read, with the reasons, as of the last listing.
    public var issues: [URL: String] {
        files.withLock { files in files.compactMapValues(\.issue) }
    }

    /// The reason a chosen file can't be used, or nil when it can.
    public func issue(with url: URL) -> String? {
        guard let modified = Self.modified(url) else { return "can't be read" }
        let file = read(url, modified: modified)
        if let issue = file.issue {
            return issue
        }
        return file.dcp == nil && file.look == nil ? "isn't a camera profile" : nil
    }

    /// The profiles for a camera, and the looks that can go over them.
    public func profiles(make: String?, model: String?) -> Found {
        guard let make, let model else { return Found() }
        let locations = currentLocations
        var candidates: [(url: URL, source: Source)] = []
        if let cameraRaw = locations.cameraRaw {
            let profiles = cameraRaw.appending(path: "CameraProfiles", directoryHint: .isDirectory)
            for url in Self.contents(of: profiles.appending(path: "Adobe Standard", directoryHint: .isDirectory))
                where url.pathExtension.lowercased() == "dcp" {
                let camera = url.deletingPathExtension().lastPathComponent
                let name = camera.range(of: " Adobe Standard").map { String(camera[..<$0.lowerBound]) } ?? camera
                if DCPProfile.names(name, camera: make, model) {
                    candidates.append((url, .adobeRaw))
                }
            }
            for folder in Self.contents(of: profiles.appending(path: "Camera", directoryHint: .isDirectory))
                where DCPProfile.names(folder.lastPathComponent, camera: make, model) {
                candidates += Self.files(in: folder, extensions: ["dcp"]).map { ($0, .cameraMatching) }
            }
            let looks = cameraRaw.appending(path: "Settings/Adobe/Profiles", directoryHint: .isDirectory)
            candidates += Self.files(in: looks, extensions: ["xmp"]).map {
                ($0, $0.pathComponents.contains("Adobe Raw") ? .adobeRaw : .creative)
            }
        }
        if let user = locations.userCameraRaw {
            candidates += Self.files(
                in: user.appending(path: "CameraProfiles", directoryHint: .isDirectory),
                extensions: ["dcp"],
            )
            .map { ($0, .own) }
            candidates += Self.files(
                in: user.appending(path: "Settings", directoryHint: .isDirectory),
                extensions: ["xmp"],
            )
            .map { ($0, .own) }
        }
        for url in locations.chosen {
            candidates += Self.files(in: url, extensions: ["dcp", "xmp"]).map { ($0, .own) }
        }

        var found = Found()
        var seen = Set<String>()
        for (url, source) in candidates {
            guard let modified = Self.modified(url) else { continue }
            let file = read(url, modified: modified)
            if let dcp = file.dcp, dcp.matchesCamera(make: make, model: model),
               seen.insert("dcp/" + dcp.identity).inserted {
                found.profiles.append(Profile(url: url, source: source == .creative ? .own : source, dcp: dcp))
            }
            if let look = file.look, look.camera.map({ DCPProfile.names($0, camera: make, model) }) ?? true,
               seen.insert("look/" + look.identity).inserted {
                found.looks.append(Look(url: url, source: Self.source(of: look, foundIn: source), look: look))
            }
        }
        return found
    }

    /// A look's group: Adobe's six Adobe Raw looks and looks made for one camera by what they are,
    /// wherever they were found.
    private static func source(of look: AdobeLook, foundIn source: Source) -> Source {
        if adobeRawLooks.contains(look.name), look.cluster == nil || look.cluster == "Adobe" {
            return .adobeRaw
        }
        if look.camera != nil {
            return .cameraMatching
        }
        return source == .adobeRaw ? .creative : source
    }

    private func read(_ url: URL, modified: Date) -> File {
        if let file = files.withLock({ $0[url] }), file.modified == modified {
            return file
        }
        var file = File(modified: modified)
        if let data = try? Data(contentsOf: url, options: .alwaysMapped) {
            if url.pathExtension.lowercased() == "dcp" {
                file.dcp = DCPProfile(data: data)
                if file.dcp == nil {
                    file.issue = "isn't a camera profile Redlamp can read"
                }
            } else if data.range(of: Data("Look".utf8)) != nil {
                do {
                    file.look = try AdobeLook(xmp: data)
                } catch .notALook {
                    // A preset, which Settings folders hold beside profiles.
                } catch {
                    file.issue = error.description
                }
            }
        } else {
            file.issue = "can't be read"
        }
        if let issue = file.issue {
            Logger(subsystem: "app.redlamp.services", category: "camera-profiles").notice(
                "\(url.lastPathComponent, privacy: .public): \(issue, privacy: .public)",
            )
        }
        files.withLock { $0[url] = file }
        return file
    }

    private static func modified(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
        guard values?.isRegularFile == true else { return nil }
        return values?.contentModificationDate
    }

    /// A folder's entries, by name; none when it's missing or can't be read.
    private static func contents(of folder: URL) -> [URL] {
        let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles],
        )
        return (entries ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// `url` when it's a file with one of `extensions`, else the files with them inside it and
    /// its subfolders, by path.
    private static func files(in url: URL, extensions: Set<String>) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else {
            return extensions.contains(url.pathExtension.lowercased()) ? [url] : []
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true },
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }
    }
}
