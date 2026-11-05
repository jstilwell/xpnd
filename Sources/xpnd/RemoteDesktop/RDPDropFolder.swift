import Foundation

/// The per-connection folder redirected into a Windows session as drive `xpnd`. Files are copied in
/// (the source stays) under names that are safe in a Windows shell; nothing outside the folder is written.
enum RDPDropFolder {
    /// Tests point this at a temporary directory.
    nonisolated(unsafe) static var root = ConnectionStore.defaultURL.deletingLastPathComponent().appending(path: "drop")

    static func url(for connectionID: Connection.ID) -> URL {
        root.appending(path: connectionID.uuidString, directoryHint: .isDirectory)
    }

    /// ASCII letters, digits, space, `_`, `-` and `.` survive; anything else (quotes, `&`, `%`, accents)
    /// becomes `_`, as does a leading dot. A taken name gets " 2", " 3"... before the extension.
    static func safeName(_ name: String, existing: Set<String>) -> String {
        var clean = String(String.UnicodeScalarView(name.unicodeScalars.map { s in
            s.isASCII && (s.properties.isAlphabetic || ("0"..."9").contains(s) || " _-.".unicodeScalars.contains(s)) ? s : "_"
        }))
        if clean.isEmpty { clean = "_" }
        if clean.hasPrefix(".") { clean = "_" + clean.dropFirst() }
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(clean.lowercased()) else { return clean }
        let ext = (clean as NSString).pathExtension
        let stem = (clean as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if !taken.contains(candidate.lowercased()) { return candidate }
            n += 1
        }
    }

    static func copyIn(_ sources: [URL], for connectionID: Connection.ID) throws -> (names: [String], failures: [URL]) {
        let fm = FileManager.default
        let folder = url(for: connectionID)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tree = root.resolvingSymlinksInPath().path + "/"
        var names: [String] = [], failures: [URL] = []
        var used = Set(try fm.contentsOfDirectory(atPath: folder.path))
        for source in sources {
            let resolved = source.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: resolved.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  !(resolved.path + "/").hasPrefix(tree) else { failures.append(source); continue }
            let name = safeName(source.lastPathComponent, existing: used)
            let destination = folder.appending(path: name)
            guard destination.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") else {
                failures.append(source); continue
            }
            do {
                try fm.copyItem(at: resolved, to: destination)
                used.insert(name)
                names.append(name)
            } catch {
                failures.append(source)
            }
        }
        return (names, failures)
    }

    static func count(for connectionID: Connection.ID) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: url(for: connectionID).path).count) ?? 0
    }

    static func clear(for connectionID: Connection.ID) throws { try clear(folder: url(for: connectionID)) }

    /// Only a folder inside `root` is ever removed.
    static func clear(folder: URL) throws {
        guard folder.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"),
              FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    static func clearAll() throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.removeItem(at: root)
    }

    static func shouldClear(policy: DropFolderCleanup, lastUse: Date?, now: Date, disconnecting: Bool) -> Bool {
        switch policy {
        case .never: false
        case .onDisconnect: disconnecting
        case .after7Days: lastUse.map { now.timeIntervalSince($0) > 7 * 86400 } ?? false
        }
    }

    /// At launch under `after7Days`: removes each connection's folder not touched for seven days.
    static func applyLaunchCleanup(policy: DropFolderCleanup, now: Date) {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for folder in folders {
            let modified = try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if shouldClear(policy: policy, lastUse: modified, now: now, disconnecting: false) { try? clear(folder: folder) }
        }
    }
}
