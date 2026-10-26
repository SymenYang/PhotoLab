import Foundation
import Synchronization

/// Where Redlamp keeps what it makes for itself.
public enum RedlampFolders {
    private static let chosenCaches = Mutex<URL?>(nil)
    private static let chosenCompiledModels = Mutex<URL?>(nil)

    /// The caches: thumbnails, focus stack merges, model compiles and embeddings, all of which can be
    /// made again. `~/Library/Caches/app.redlamp`, shared by the app and the command-line tool, unless
    /// the process sets another before anything reads it, as a test run does to keep what it makes
    /// out of the user's.
    public static var caches: URL {
        get {
            chosenCaches.withLock { $0 } ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appending(path: "app.redlamp", directoryHint: .isDirectory)
        }
        set {
            chosenCaches.withLock { $0 = newValue }
        }
    }

    /// The model compiles: `CompiledModels` in the caches, unless the process sets another folder
    /// before anything reads it. Core ML keeps what it specialises from a compile for this Mac by the
    /// compile's path and files, and doesn't remove it, so a compile copied or made again leaves
    /// another behind: test runs, whose caches are each their own, share one folder of compiles.
    public static var compiledModels: URL {
        get {
            chosenCompiledModels.withLock { $0 }
                ?? caches.appending(path: "CompiledModels", directoryHint: .isDirectory)
        }
        set {
            chosenCompiledModels.withLock { $0 = newValue }
        }
    }
}
