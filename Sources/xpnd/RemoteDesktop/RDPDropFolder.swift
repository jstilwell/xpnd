import Foundation

/// The per-connection folder redirected into a Windows session as drive `xpnd`. Files are copied in
/// (the source stays) under names that are safe in a Windows shell; nothing outside the folder is written.
enum RDPDropFolder {
    /// `hasFolder`: a directory is among the failures, which aren't otherwise told apart.
    typealias CopyResult = (names: [String], failures: [URL], hasFolder: Bool)

    /// Tests point this at a temporary directory.
    nonisolated(unsafe) static var root = ConnectionStore.defaultURL.deletingLastPathComponent().appending(path: "drop")

    static func url(for connectionID: Connection.ID) -> URL {
        root.appending(path: connectionID.uuidString, directoryHint: .isDirectory)
    }

    /// Before a connect: on first use, or after a cleanup, there is no folder to redirect.
    static func ensureExists(folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private static let reservedDeviceNames: Set<String> =
        Set(["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] })

    /// ASCII letters, digits, space, `_`, `-` and `.` survive; anything else (quotes, `&`, `%`, accents)
    /// becomes `_`, as does a leading dot. A taken name gets " 2", " 3"... before the extension.
    static func safeName(_ name: String, existing: Set<String>) -> String {
        var clean = String(String.UnicodeScalarView(name.unicodeScalars.map { s in
            s.isASCII && (s.properties.isAlphabetic || ("0"..."9").contains(s) || " _-.".unicodeScalars.contains(s)) ? s : "_"
        }))
        if clean.hasPrefix(".") { clean = "_" + clean.dropFirst() }
        // Windows drops a trailing dot or space and refuses device names (CON, COM1.txt...).
        while let last = clean.last, last == "." || last == " " { clean.removeLast() }
        if clean.isEmpty { clean = "_" }
        let device = clean.prefix { $0 != "." }.uppercased().trimmingCharacters(in: .whitespaces)
        if reservedDeviceNames.contains(device) { clean = "_" + clean }
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

    private static let copies = DispatchQueue(label: "com.jessestilwell.xpnd.drop-copy")

    /// `copyIn`, off the caller's thread and one drop at a time, so two can't pick the same safe name (duplicate
    /// tabs share a folder). A dispatch queue, not the cooperative pool: a copy from a NAS can block for minutes.
    // shortcut: one queue for every connection, so a slow copy holds up another tab's drop; make it per folder if that bites.
    static func copyInTurn(_ sources: [URL], folder: URL) async throws -> CopyResult {
        try await withCheckedThrowingContinuation { continuation in
            copies.async { continuation.resume(with: Result { try copyIn(sources, folder: folder) }) }
        }
    }

    static func copyIn(_ sources: [URL], folder: URL) throws -> CopyResult {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tree = root.resolvingSymlinksInPath().path + "/"
        var names: [String] = [], failures: [URL] = [], hasFolder = false
        var used = Set(try fm.contentsOfDirectory(atPath: folder.path))
        for source in sources {
            let resolved = source.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: resolved.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  !(resolved.path + "/").hasPrefix(tree) else {
                failures.append(source)
                hasFolder = hasFolder || isDirectory.boolValue
                continue
            }
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
        return (names, failures, hasFolder)
    }

    /// What a person would count: `.DS_Store` and the like are skipped, though `clear` removes them.
    static func count(folder: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }.count) ?? 0
    }

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

    // shortcut: a folder's modification date stands in for last use, so one still being read can look old and one with an unreadable date is never cleared; record real last use if that bites.
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
