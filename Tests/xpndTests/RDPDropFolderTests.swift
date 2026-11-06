import Foundation
import AppKit
import Testing
@testable import xpnd
import xpndRDP

/// `RDPDropFolder.root` is global: these run one at a time, each in its own temporary directory.
@Suite(.serialized) struct RDPDropFolderTests {
    private func inTemp(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "xpnd-drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let saved = RDPDropFolder.root
        RDPDropFolder.root = dir.appending(path: "drop")
        defer { RDPDropFolder.root = saved; try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private func inTemp(_ body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "xpnd-drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let saved = RDPDropFolder.root
        RDPDropFolder.root = dir.appending(path: "drop")
        defer { RDPDropFolder.root = saved; try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }

    private func file(_ name: String, in dir: URL, _ text: String = "data") throws -> URL {
        let url = dir.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func ensureExistsMakesAPrivateFolderAndLeavesOneThatIsThere() throws {
        try inTemp { _ in
            let folder = RDPDropFolder.url(for: UUID())
            RDPDropFolder.ensureExists(folder: folder)
            let mode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
            #expect(mode == 0o700)
            try Data("x".utf8).write(to: folder.appending(path: "a.txt"))
            RDPDropFolder.ensureExists(folder: folder)
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: "a.txt").path))
        }
    }

    @Test func safeNamesStripShellCharacters() {
        #expect(RDPDropFolder.safeName("x\" & calc & \".txt", existing: []) == "x_ _ calc _ _.txt")
        #expect(RDPDropFolder.safeName("%PATH%.txt", existing: []) == "_PATH_.txt")
        #expect(RDPDropFolder.safeName(".hidden", existing: []) == "_hidden")
        #expect(RDPDropFolder.safeName("résumé.pdf", existing: []) == "r_sum_.pdf")
        #expect(RDPDropFolder.safeName("ok-name_1.txt", existing: []) == "ok-name_1.txt")
    }

    @Test func safeNamesAvoidWhatWindowsRejects() {
        let expected = ["foo.": "foo", "foo .": "foo", "...": "_", " ": "_", "CON.txt": "_CON.txt", "nul": "_nul",
                        "COM1.log": "_COM1.log", "LPT9": "_LPT9", "con .txt": "_con .txt", "CONSOLE.txt": "CONSOLE.txt", "COM10.txt": "COM10.txt"]
        for (input, output) in expected { #expect(RDPDropFolder.safeName(input, existing: []) == output, "\(input)") }
        #expect(RDPDropFolder.safeName("foo.", existing: ["foo"]) == "foo 2")
        #expect(RDPDropFolder.safeName("nul", existing: ["_nul"]) == "_nul 2")
    }

    @Test func collisionsGetANumber() {
        #expect(RDPDropFolder.safeName("a.txt", existing: ["a.txt", "a 2.txt"]) == "a 3.txt")
    }

    @Test func copyInKeepsTheSourceAndReturnsNames() throws {
        try inTemp { dir in
            let id = UUID()
            let a = try file("a.txt", in: dir, "one")
            let b = try file("b&.txt", in: dir, "two")
            let result = try RDPDropFolder.copyIn([a, b, a], folder: RDPDropFolder.url(for: id))
            #expect(result.names == ["a.txt", "b_.txt", "a 2.txt"])
            #expect(result.failures.isEmpty)
            #expect(FileManager.default.fileExists(atPath: a.path))
            #expect(try String(contentsOf: RDPDropFolder.url(for: id).appending(path: "b_.txt"), encoding: .utf8) == "two")
            #expect(RDPDropFolder.count(folder: RDPDropFolder.url(for: id)) == 3)
            let mode = try FileManager.default.attributesOfItem(atPath: RDPDropFolder.url(for: id).path)[.posixPermissions] as? Int
            #expect(mode == 0o700)
        }
    }

    @Test func hiddenFilesAreNotCountedButAreCleared() throws {
        try inTemp { _ in
            let folder = RDPDropFolder.url(for: UUID())
            RDPDropFolder.ensureExists(folder: folder)
            try Data("x".utf8).write(to: folder.appending(path: ".DS_Store"))
            #expect(RDPDropFolder.count(folder: folder) == 0)
            try Data("x".utf8).write(to: folder.appending(path: "a.txt"))
            #expect(RDPDropFolder.count(folder: folder) == 1)
            try RDPDropFolder.clear(folder: folder)
            #expect(!FileManager.default.fileExists(atPath: folder.appending(path: ".DS_Store").path))
        }
    }

    @Test func copyInSaysWhetherAFolderWasAmongTheFailures() throws {
        try inTemp { dir in
            let id = UUID()
            let missing = dir.appending(path: "missing.txt")
            #expect(!(try RDPDropFolder.copyIn([missing], folder: RDPDropFolder.url(for: id))).hasFolder)
            let folder = dir.appending(path: "folder")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let result = try RDPDropFolder.copyIn([missing, folder], folder: RDPDropFolder.url(for: id))
            #expect(result.failures.count == 2)
            #expect(result.hasFolder)
        }
    }

    @Test func dropsCopiedAtOnceGoInTurnAndNeverShareAName() async throws {
        try await inTemp { dir in
            let folder = RDPDropFolder.url(for: UUID())
            let a = try file("a.txt", in: dir)
            let results = try await withThrowingTaskGroup(of: [String].self) { group in
                for _ in 0..<8 { group.addTask { try await RDPDropFolder.copyInTurn([a, a], folder: folder).names } }
                return try await group.reduce(into: []) { $0 += $1 }
            }
            #expect(results.count == 16)
            #expect(Set(results).count == 16)
            #expect(RDPDropFolder.count(folder: folder) == 16)
        }
    }

    @Test func copyInResolvesSymlinksAndStaysInside() throws {
        try inTemp { dir in
            let id = UUID()
            let target = try file("target.txt", in: dir, "bytes")
            let link = dir.appending(path: "link.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let dotdot = URL(fileURLWithPath: "..", relativeTo: dir)
            let missing = dir.appending(path: "missing.txt")
            let result = try RDPDropFolder.copyIn([link, dotdot, missing], folder: RDPDropFolder.url(for: id))
            #expect(result.names == ["link.txt"])
            #expect(result.failures.count == 2)
            let folder = RDPDropFolder.url(for: id)
            #expect(try String(contentsOf: folder.appending(path: "link.txt"), encoding: .utf8) == "bytes")
            // A file already in the drop tree is refused.
            let again = try RDPDropFolder.copyIn([folder.appending(path: "link.txt")], folder: RDPDropFolder.url(for: id))
            #expect(again.names.isEmpty && again.failures.count == 1)
            let outside = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
            #expect(outside == ["drop", "link.txt", "target.txt"])
        }
    }

    @Test func clearRemovesEverything() throws {
        try inTemp { dir in
            let one = UUID(), two = UUID()
            _ = try RDPDropFolder.copyIn([try file("a.txt", in: dir)], folder: RDPDropFolder.url(for: one))
            _ = try RDPDropFolder.copyIn([try file("a.txt", in: dir)], folder: RDPDropFolder.url(for: two))
            try RDPDropFolder.clear(folder: RDPDropFolder.url(for: one))
            #expect(RDPDropFolder.count(folder: RDPDropFolder.url(for: one)) == 0)
            #expect(RDPDropFolder.count(folder: RDPDropFolder.url(for: two)) == 1)
            try RDPDropFolder.clearAll()
            #expect(RDPDropFolder.count(folder: RDPDropFolder.url(for: two)) == 0)
            try RDPDropFolder.clear(folder: RDPDropFolder.url(for: one)) // already gone is fine
        }
    }

    @Test func cleanupPolicy() {
        let now = Date()
        let old = now.addingTimeInterval(-8 * 86400), recent = now.addingTimeInterval(-86400)
        #expect(!RDPDropFolder.shouldClear(policy: .never, lastUse: old, now: now, disconnecting: true))
        #expect(RDPDropFolder.shouldClear(policy: .onDisconnect, lastUse: nil, now: now, disconnecting: true))
        #expect(!RDPDropFolder.shouldClear(policy: .onDisconnect, lastUse: old, now: now, disconnecting: false))
        #expect(RDPDropFolder.shouldClear(policy: .after7Days, lastUse: old, now: now, disconnecting: false))
        #expect(!RDPDropFolder.shouldClear(policy: .after7Days, lastUse: recent, now: now, disconnecting: true))
    }

    @Test func launchCleanupRemovesOnlyOldFoldersUnderTheSevenDayPolicy() throws {
        try inTemp { dir in
            let oldID = UUID(), newID = UUID()
            _ = try RDPDropFolder.copyIn([try file("a.txt", in: dir)], folder: RDPDropFolder.url(for: oldID))
            _ = try RDPDropFolder.copyIn([try file("a.txt", in: dir)], folder: RDPDropFolder.url(for: newID))
            let now = Date()
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-9 * 86400)], ofItemAtPath: RDPDropFolder.url(for: oldID).path)
            RDPDropFolder.applyLaunchCleanup(policy: .never, now: now)
            #expect(RDPDropFolder.count(folder: RDPDropFolder.url(for: oldID)) == 1)
            RDPDropFolder.applyLaunchCleanup(policy: .after7Days, now: now)
            #expect(RDPDropFolder.count(folder: RDPDropFolder.url(for: oldID)) == 0)
            #expect(RDPDropFolder.count(folder: RDPDropFolder.url(for: newID)) == 1)
        }
    }
}

/// Same suite-level serialization need as above (they set `RDPDropFolder.root`): nested so the parent's `.serialized` covers them.
extension RDPDropFolderTests {
@Suite @MainActor struct HostEnd {
    private let fake = FakeSession()

    /// A host whose drop folder is in a temporary root, holding one file; restores the root afterwards.
    private func dropHost(_ policy: DropFolderCleanup, body: (RDPHost, XPRDPSession, URL) async -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "xpnd-host-\(UUID().uuidString)")
        let saved = RDPDropFolder.root
        RDPDropFolder.root = dir.appending(path: "drop")
        defer { RDPDropFolder.root = saved; try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let folder = RDPDropFolder.url(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appending(path: "a.txt"))
        var config = RDPOptions().resolved(over: .standard, host: "win", port: 3389, username: "me", domain: nil, dropFolder: folder.path)
        config.reconnectTries = 2
        let fake = fake
        let host = RDPHost(config: config, password: "p", gatewayPassword: nil, presentIn: { nil }, retryDelay: .zero,
                           cleanup: { policy }, makeSession: { _, _, _, _, _ in fake })
        await body(host, XPRDPSession(settings: [], password: "", gatewayPassword: nil, delegate: host), folder)
    }

    /// A host over a temporary root with no folder yet; `folderThere` records whether it existed at each connect.
    private func hostWithoutFolder(dropDrive: Bool = true,
                                   body: @MainActor (RDPHost, XPRDPSession, URL, @MainActor () -> [Bool], (name: String, path: String)?) async -> Void) async {
        let dir = FileManager.default.temporaryDirectory.appending(path: "xpnd-host-\(UUID().uuidString)")
        let saved = RDPDropFolder.root
        RDPDropFolder.root = dir.appending(path: "drop")
        defer { RDPDropFolder.root = saved; try? FileManager.default.removeItem(at: dir) }
        let folder = RDPDropFolder.url(for: UUID())
        var config = RDPOptions().resolved(over: .standard, host: "win", port: 3389, username: "me", domain: nil, dropFolder: folder.path)
        config.dropDrive = dropDrive
        config.reconnectTries = 2
        let session = FakeSession()
        var there: [Bool] = []
        session.onConnect = { there.append(FileManager.default.fileExists(atPath: folder.path)) }
        var drive: (name: String, path: String)?
        let host = RDPHost(config: config, password: "p", gatewayPassword: nil, presentIn: { nil }, retryDelay: .zero, cleanup: { .never },
                           makeSession: { _, _, _, d, _ in drive = d; return session })
        await body(host, XPRDPSession(settings: [], password: "", gatewayPassword: nil, delegate: host), folder, { there }, drive)
    }

    @Test func theDriveReachesTheSession() async {
        await hostWithoutFolder { _, _, folder, _, drive in
            #expect(drive?.name == "xpnd")
            #expect(drive?.path == folder.path)
        }
        await hostWithoutFolder(dropDrive: false) { _, _, _, _, drive in #expect(drive == nil) }
    }

    @Test func theFolderExistsBeforeEveryConnect() async {
        await hostWithoutFolder { host, s, folder, there, _ in
            #expect(there() == [true])  // first use
            try? FileManager.default.removeItem(at: folder)  // cleanup on disconnect, then Reconnect
            host.reconnect()
            #expect(there() == [true, true])
            host.sessionDidConnect(s)
            try? FileManager.default.removeItem(at: folder)
            host.session(s, didDisconnectWithErrorName: "ERRCONNECT_CONNECT_TRANSPORT_FAILED")
            await host.retry?.value
            #expect(there() == [true, true, true])
        }
    }

    @Test func noDriveMakesNoFolder() async {
        await hostWithoutFolder(dropDrive: false) { host, _, _, there, _ in
            host.reconnect()
            #expect(there() == [false, false])
        }
    }

    @Test func theDropFolderIsClearedOnlyWhenTheSessionReallyEnds() async throws {
        try await dropHost(.onDisconnect) { host, s, folder in
            host.sessionDidConnect(s)
            host.session(s, didDisconnectWithErrorName: "ERRCONNECT_CONNECT_TRANSPORT_FAILED")
            await host.retry?.value
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: "a.txt").path)) // a retry keeps the files
            host.session(s, didDisconnectWithErrorName: "ERRCONNECT_CONNECT_TRANSPORT_FAILED")
            await host.retry?.value
            host.session(s, didDisconnectWithErrorName: "ERRCONNECT_CONNECT_TRANSPORT_FAILED")
            #expect(!FileManager.default.fileExists(atPath: folder.path))
        }
    }

    @Test func theDropFolderStaysUnderOtherPoliciesAndIsClearedWhenTheTabCloses() async throws {
        try await dropHost(.never) { host, _, folder in
            host.terminate()
            #expect(FileManager.default.fileExists(atPath: folder.path))
        }
        try await dropHost(.onDisconnect) { host, _, folder in
            host.terminate()
            #expect(!FileManager.default.fileExists(atPath: folder.path))
        }
    }
}
}
