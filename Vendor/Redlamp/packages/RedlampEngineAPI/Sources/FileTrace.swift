import Foundation
import Synchronization

/// The file operations a bench follows while it's on (LIB-53): sidecars read and written, thumbnails read, and
/// the operations of a simulated volume, in the order they ran, so RedlampLibrary can replay them through a
/// simulated disk (`DiskReplay`). Off, as it is outside benches, an operation costs one relaxed atomic load.
public enum FileTrace {
    public enum Kind: String, Sendable, Hashable, CaseIterable, Comparable {
        /// A file's or folder's attributes, or whether something is there.
        case stat
        case read
        /// A folder's entries.
        case list
        /// A file made and its bytes written.
        case create
        case rename
        case makeFolder
        case remove
        /// The file coordinator asked for a file's conflicting versions.
        case versions

        public static func < (lhs: Kind, rhs: Kind) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    public struct Operation: Sendable, Hashable {
        public let kind: Kind
        public let path: String
        public let bytes: Int
        /// What it was made for, as `marking` said where it ran; nil when nothing did.
        public let purpose: String?

        public init(kind: Kind, path: String, bytes: Int = 0, purpose: String? = nil) {
            self.kind = kind
            self.path = path
            self.bytes = bytes
            self.purpose = purpose
        }
    }

    /// What a photo's thumbnail reads, as `marking` names it.
    public static let thumbnail = "thumbnail"

    private static let following = Atomic(false)
    private static let recorded = Mutex<[Operation]>([])
    private static let purposeKey = "app.redlamp.file-trace.purpose"

    /// Starts following operations, forgetting any followed before.
    public static func start() {
        recorded.withLock { $0 = [] }
        following.store(true, ordering: .sequentiallyConsistent)
    }

    /// Stops following them, and returns those followed since `start`.
    @discardableResult
    public static func stop() -> [Operation] {
        following.store(false, ordering: .sequentiallyConsistent)
        return recorded.withLock { operations in
            defer { operations = [] }
            return operations
        }
    }

    /// Whether operations are followed now, for a note whose size costs something to find.
    public static var isOn: Bool {
        following.load(ordering: .relaxed)
    }

    public static func note(_ kind: Kind, _ url: URL, bytes: Int = 0) {
        guard following.load(ordering: .relaxed) else { return }
        note(kind, path: url.path, bytes: bytes)
    }

    public static func note(_ kind: Kind, path: String, bytes: Int = 0) {
        guard following.load(ordering: .relaxed) else { return }
        let purpose = Thread.current.threadDictionary[purposeKey] as? String
        recorded.withLock { $0.append(Operation(kind: kind, path: path, bytes: bytes, purpose: purpose)) }
    }

    /// Runs `body`, the operations it notes on this thread made for `purpose`, so a bench can tell
    /// them from the rest.
    public static func marking<T>(_ purpose: String, _ body: () throws -> T) rethrows -> T {
        guard following.load(ordering: .relaxed) else { return try body() }
        let thread = Thread.current.threadDictionary
        let outer = thread[purposeKey]
        thread[purposeKey] = purpose
        defer { thread[purposeKey] = outer }
        return try body()
    }
}
