import Foundation
import Observation

enum StoreError: Error, Equatable {
    case fileUnreadable
    case duplicateKeyword(String)
    /// `SnippetYAML.encode` fell back to empty text; writing it would wipe the file.
    case encodingFailed
}

@MainActor @Observable
final class SnippetStore {
    nonisolated static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "xpnd/snippets.yaml")
    }

    private(set) var library = SnippetLibrary.empty
    private(set) var loadError: String?

    @ObservationIgnored private let fileURL: URL
    /// Last text this store read or wrote; the watcher reloads only when the file differs.
    @ObservationIgnored private var lastText: String?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return } // missing file: empty library, no error
        let text = String(decoding: data, as: UTF8.self)
        lastText = text
        do {
            library = try SnippetYAML.decode(text)
            loadError = nil
        } catch {
            loadError = "\(error)"
        }
    }

    func update(_ change: (inout SnippetLibrary) -> Void) throws(StoreError) {
        guard loadError == nil else { throw .fileUnreadable }
        var next = library
        change(&next)
        if let dup = next.duplicateKeywords.first { throw .duplicateKeyword(dup) }
        let text = SnippetYAML.encode(next)
        if text.isEmpty && !next.groups.isEmpty { throw .encodingFailed }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: fileURL, options: .atomic)
        } catch {
            throw .fileUnreadable
        }
        lastText = text
        library = next
    }

    func startWatching() {
        guard watcher == nil else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reloadIfChanged() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    private func reloadIfChanged() {
        guard let data = try? Data(contentsOf: fileURL),
              String(decoding: data, as: UTF8.self) != lastText else { return }
        load()
    }
}
