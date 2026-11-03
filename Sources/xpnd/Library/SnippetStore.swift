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
    @ObservationIgnored private var fileWatcher: DispatchSourceFileSystemObject?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    private enum Disk { case missing, text(String), unreadable }

    private func readDisk() -> Disk {
        do {
            guard let text = String(data: try Data(contentsOf: fileURL), encoding: .utf8) else { return .unreadable }
            return .text(text)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .missing
        } catch {
            return .unreadable
        }
    }

    func load() {
        switch readDisk() {
        case .missing: return // empty library, no error
        case .unreadable: loadError = "Could not read \(fileURL.lastPathComponent)"
        case .text(let text):
            lastText = text
            do {
                library = try SnippetYAML.decode(text)
                loadError = nil
            } catch {
                loadError = "\(error)"
            }
        }
    }

    func update(_ change: (inout SnippetLibrary) -> Void) throws(StoreError) {
        // Pick up external edits the watcher hasn't delivered yet (or without a watcher).
        if case .text(let onDisk) = readDisk(), onDisk == lastText {} else { load() }
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
        guard let source = makeSource(path: dir.path, mask: .write, handler: { [weak self] _ in
            self?.reloadIfChanged()
            self?.armFileWatcher() // an atomic rename swaps the inode
        }) else { return }
        watcher = source
        armFileWatcher()
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
        fileWatcher?.cancel()
        fileWatcher = nil
    }

    /// Directory events miss in-place edits, so also watch the file itself.
    private func armFileWatcher() {
        fileWatcher?.cancel()
        fileWatcher = makeSource(path: fileURL.path, mask: [.write, .extend, .delete, .rename]) { [weak self] flags in
            self?.reloadIfChanged()
            if !flags.isDisjoint(with: [.delete, .rename]) { self?.armFileWatcher() }
        }
    }

    private func makeSource(
        path: String, mask: DispatchSource.FileSystemEvent,
        handler: @escaping @MainActor (DispatchSource.FileSystemEvent) -> Void
    ) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        source.setEventHandler { [source] in
            let flags = source.data
            MainActor.assumeIsolated { handler(flags) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func reloadIfChanged() {
        if case .text(let onDisk) = readDisk(), onDisk == lastText { return }
        load()
    }
}
