import Foundation
struct CleanupEntry: Codable {
    let source: String
    let token: String
    let removable: Bool
    let bytes: Int
}
@main struct Cleanup {
    static func main() throws {
        let args = CommandLine.arguments
        if args[1] == "--apply" {
            let entries = try JSONDecoder().decode([CleanupEntry].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
            for entry in entries where entry.removable {
                let source = URL(fileURLWithPath: entry.source)
                guard let envelope = try PhotoEditStore.read(source), envelope.token == entry.token,
                      envelope.document.versions.allSatisfy({ !$0.adjustments.hasEffectiveChanges }),
                      try PhotoEditStore.sourceMatches(source, document: envelope.document) else { throw CatalogError(message: "清理对象在核查后发生变化：\(source.path)") }
                let remaining = try PhotoEditStore.commit(envelope.document, source: source, expectedToken: entry.token, cache: false)
                guard remaining == nil, !FileManager.default.fileExists(atPath: PhotoEditStore.sidecar(source).path) else { throw CatalogError(message: "清理失败") }
                print("DELETED \(PhotoEditStore.sidecar(source).path)")
            }
        } else {
            var entries: [CleanupEntry] = []
            for path in args.dropFirst(2) {
                let source = URL(fileURLWithPath: path).deletingPathExtension()
                guard let envelope = try PhotoEditStore.read(source) else { continue }
                let removable = try envelope.document.versions.allSatisfy({ !$0.adjustments.hasEffectiveChanges }) && (PhotoEditStore.sourceMatches(source, document: envelope.document))
                let bytes = (try FileManager.default.attributesOfItem(atPath: path)[.size] as! NSNumber).intValue
                entries.append(CleanupEntry(source: source.path, token: envelope.token, removable: removable, bytes: bytes))
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try encoder.encode(entries).write(to: URL(fileURLWithPath: args[1]))
            print("Checked \(entries.count); removable \(entries.filter(\.removable).count)")
        }
    }
}
