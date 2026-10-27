import AppKit
import UniformTypeIdentifiers

final class FilePresentation {
    let icon: NSImage
    let createdText: String
    let modified: Date
    let size: Int64
    init(icon: NSImage, createdText: String, hit: SearchHit) {
        self.icon = icon
        self.createdText = createdText
        modified = hit.modified
        size = hit.size
    }
}

/// Bounded workers serve visible rows. Ordinary files share a type icon,
/// avoiding custom-icon and thumbnail lookups for every file while scrolling.
final class FilePresentationLoader: @unchecked Sendable {
    static let shared = FilePresentationLoader()
    private let cache = NSCache<NSString, FilePresentation>()
    private let icons = NSCache<NSString, NSImage>()
    private let queue = OperationQueue()

    private init() {
        cache.countLimit = 2048
        icons.countLimit = 256
        queue.name = "FSearch.visible-file-metadata"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
    }

    func cached(_ hit: SearchHit) -> FilePresentation? {
        guard let value = cache.object(forKey: hit.path as NSString), value.modified == hit.modified, value.size == hit.size else { return nil }
        return value
    }

    func load(_ hit: SearchHit, completion: @escaping (FilePresentation) -> Void) -> Operation {
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak operation] in
            guard let operation, !operation.isCancelled else { return }
            let value: FilePresentation
            if let cached = self.cached(hit) { value = cached }
            else {
                let url = URL(fileURLWithPath: hit.path)
                let type = hit.isDirectory ? UTType.folder : UTType(filenameExtension: url.pathExtension) ?? .data
                let icon: NSImage
                if url.pathExtension.lowercased() == "app" { icon = NSWorkspace.shared.icon(forFile: hit.path) }
                else if let cached = self.icons.object(forKey: type.identifier as NSString) { icon = cached }
                else {
                    icon = NSWorkspace.shared.icon(for: type)
                    self.icons.setObject(icon, forKey: type.identifier as NSString)
                }
                guard !operation.isCancelled else { return }
                let created = hit.created ?? (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                value = FilePresentation(icon: icon, createdText: created?.formatted(SearchFormatting.date) ?? "—", hit: hit)
                self.cache.setObject(value, forKey: hit.path as NSString)
            }
            guard !operation.isCancelled else { return }
            DispatchQueue.main.async {
                guard !operation.isCancelled else { return }
                completion(value)
            }
        }
        queue.addOperation(operation)
        return operation
    }
}
