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

    private func file(_ name: String, in dir: URL, _ text: String = "data") throws -> URL {
        let url = dir.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func safeNamesStripShellCharacters() {
        #expect(RDPDropFolder.safeName("x\" & calc & \".txt", existing: []) == "x_ _ calc _ _.txt")
        #expect(RDPDropFolder.safeName("%PATH%.txt", existing: []) == "_PATH_.txt")
        #expect(RDPDropFolder.safeName(".hidden", existing: []) == "_hidden")
        #expect(RDPDropFolder.safeName("résumé.pdf", existing: []) == "r_sum_.pdf")
        #expect(RDPDropFolder.safeName("ok-name_1.txt", existing: []) == "ok-name_1.txt")
    }

    @Test func collisionsGetANumber() {
        #expect(RDPDropFolder.safeName("a.txt", existing: ["a.txt", "a 2.txt"]) == "a 3.txt")
    }

    @Test func copyInKeepsTheSourceAndReturnsNames() throws {
        try inTemp { dir in
            let id = UUID()
            let a = try file("a.txt", in: dir, "one")
            let b = try file("b&.txt", in: dir, "two")
            let result = try RDPDropFolder.copyIn([a, b, a], for: id)
            #expect(result.names == ["a.txt", "b_.txt", "a 2.txt"])
            #expect(result.failures.isEmpty)
            #expect(FileManager.default.fileExists(atPath: a.path))
            #expect(try String(contentsOf: RDPDropFolder.url(for: id).appending(path: "b_.txt"), encoding: .utf8) == "two")
            #expect(RDPDropFolder.count(for: id) == 3)
            let mode = try FileManager.default.attributesOfItem(atPath: RDPDropFolder.url(for: id).path)[.posixPermissions] as? Int
            #expect(mode == 0o700)
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
            let result = try RDPDropFolder.copyIn([link, dotdot, missing], for: id)
            #expect(result.names == ["link.txt"])
            #expect(result.failures.count == 2)
            let folder = RDPDropFolder.url(for: id)
            #expect(try String(contentsOf: folder.appending(path: "link.txt"), encoding: .utf8) == "bytes")
            // A file already in the drop tree is refused.
            let again = try RDPDropFolder.copyIn([folder.appending(path: "link.txt")], for: id)
            #expect(again.names.isEmpty && again.failures.count == 1)
            let outside = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
            #expect(outside == ["drop", "link.txt", "target.txt"])
        }
    }

    @Test func clearRemovesEverything() throws {
        try inTemp { dir in
            let one = UUID(), two = UUID()
            _ = try RDPDropFolder.copyIn([try file("a.txt", in: dir)], for: one)
            _ = try RDPDropFolder.copyIn([try file("a.txt", in: dir)], for: two)
            try RDPDropFolder.clear(for: one)
            #expect(RDPDropFolder.count(for: one) == 0)
            #expect(RDPDropFolder.count(for: two) == 1)
            try RDPDropFolder.clearAll()
            #expect(RDPDropFolder.count(for: two) == 0)
            try RDPDropFolder.clear(for: one) // already gone is fine
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
            _ = try RDPDropFolder.copyIn([try file("a.txt", in: dir)], for: oldID)
            _ = try RDPDropFolder.copyIn([try file("a.txt", in: dir)], for: newID)
            let now = Date()
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-9 * 86400)], ofItemAtPath: RDPDropFolder.url(for: oldID).path)
            RDPDropFolder.applyLaunchCleanup(policy: .never, now: now)
            #expect(RDPDropFolder.count(for: oldID) == 1)
            RDPDropFolder.applyLaunchCleanup(policy: .after7Days, now: now)
            #expect(RDPDropFolder.count(for: oldID) == 0)
            #expect(RDPDropFolder.count(for: newID) == 1)
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
                           cleanup: { policy }, makeSession: { _, _, _, _ in fake })
        await body(host, XPRDPSession(settings: [], password: "", gatewayPassword: nil, delegate: host), folder)
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
