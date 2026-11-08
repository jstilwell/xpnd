import Foundation
import Testing
@testable import xpnd

@MainActor
private func withTempDir(_ body: (URL) async throws -> Void) async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try await body(dir)
}

private func group(_ keywords: String...) -> SnippetGroup {
    SnippetGroup(name: "G", snippets: keywords.map { Snippet(name: $0, keyword: $0, text: "x") })
}

@MainActor
private func eventually(_ cond: () -> Bool) async -> Bool {
    for _ in 0..<40 {
        if cond() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return cond()
}

@MainActor
struct SnippetStoreTests {
    @Test func missingFileLoadsEmptyAndWritesNothing() async throws {
        try await withTempDir { dir in
            let url = dir.appending(path: "snippets.yaml")
            let store = SnippetStore(fileURL: url)
            store.load()
            #expect(store.library == .empty)
            #expect(store.loadError == nil)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func deletingBrokenFileRecovers() async throws {
        try await withTempDir { dir in
            let url = dir.appending(path: "snippets.yaml")
            let store = SnippetStore(fileURL: url)
            try store.update { $0.groups.append(group(";a")) }
            try Data("groups: [".utf8).write(to: url, options: .atomic)
            store.load()
            #expect(store.loadError != nil)
            try FileManager.default.removeItem(at: url)
            store.load()
            #expect(store.loadError == nil)
            #expect(store.library == .empty)
            // Saving works again, starting from the empty library.
            try store.update { $0.groups.append(group(";b")) }
            #expect(store.library.groups.flatMap(\.snippets).map(\.keyword) == [";b"])
        }
    }

    @Test func updateSavesAndReloads() async throws {
        try await withTempDir { dir in
            let url = dir.appending(path: "sub/snippets.yaml")
            let store = SnippetStore(fileURL: url)
            try store.update { $0.groups.append(group(";a")) }
            let other = SnippetStore(fileURL: url)
            other.load()
            #expect(other.library.groups.first?.snippets.first?.keyword == ";a")
        }
    }

    @Test func saveLeavesNoTempFiles() async throws {
        try await withTempDir { dir in
            let store = SnippetStore(fileURL: dir.appending(path: "snippets.yaml"))
            try store.update { $0.groups.append(group(";a")) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["snippets.yaml"])
        }
    }

    @Test func saveKeepsASymlinkedFile() async throws {
        try await withTempDir { dir in
            let real = dir.appending(path: "dotfiles/snippets.yaml")
            try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "version: 1\ngroups: []\n".write(to: real, atomically: true, encoding: .utf8)
            let link = dir.appending(path: "snippets.yaml")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            let store = SnippetStore(fileURL: link)
            store.load()
            try store.update { $0.groups.append(group(";a")) }
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
            #expect(try String(contentsOf: real, encoding: .utf8).contains(";a"))
        }
    }

    @Test func malformedFileIsNeverOverwritten() async throws {
        try await withTempDir { dir in
            let url = dir.appending(path: "snippets.yaml")
            let bad = Data("groups: [".utf8)
            try bad.write(to: url)
            let store = SnippetStore(fileURL: url)
            store.load()
            #expect(store.loadError != nil)
            #expect(throws: StoreError.fileUnreadable) { try store.update { $0.groups.append(group(";a")) } }
            #expect(try Data(contentsOf: url) == bad)
        }
    }

    @Test func duplicateKeywordIsRefused() async throws {
        try await withTempDir { dir in
            let url = dir.appending(path: "snippets.yaml")
            let store = SnippetStore(fileURL: url)
            try store.update { $0.groups.append(group(";a")) }
            let before = try Data(contentsOf: url)
            #expect(throws: StoreError.duplicateKeyword(";a")) {
                try store.update { $0.groups.append(group(";a")) }
            }
            #expect(try Data(contentsOf: url) == before)
            #expect(store.library.groups.count == 1)
        }
    }

    @Test func externalEditReloads() async throws {
        try await withTempDir { dir in
            let url = dir.appending(path: "snippets.yaml")
            let store = SnippetStore(fileURL: url)
            try store.update { $0.groups.append(group(";a")) }
            store.startWatching()
            defer { store.stopWatching() }
            let yaml = SnippetYAML.encode(SnippetLibrary(groups: [group(";b")]))
            try Data(yaml.utf8).write(to: url, options: .atomic)
            #expect(await eventually { store.library.groups.first?.snippets.first?.keyword == ";b" })
        }
    }

    @Test func externalInvalidEditKeepsLastGoodLibrary() async throws {
        try await withTempDir { dir in
            let url = dir.appending(path: "snippets.yaml")
            let store = SnippetStore(fileURL: url)
            try store.update { $0.groups.append(group(";a")) }
            let good = store.library
            store.startWatching()
            defer { store.stopWatching() }
            try Data("groups: [".utf8).write(to: url, options: .atomic)
            #expect(await eventually { store.loadError != nil })
            #expect(store.library == good)
            #expect(try String(contentsOf: url, encoding: .utf8) == "groups: [")
        }
    }

    @Test func inPlaceEditReloads() async throws {
        try await withTempDir { dir in
            let url = dir.appending(path: "snippets.yaml")
            let store = SnippetStore(fileURL: url)
            try store.update { $0.groups.append(group(";a")) }
            store.startWatching()
            defer { store.stopWatching() }
            let yaml = SnippetYAML.encode(SnippetLibrary(groups: [group(";b")]))
            try Data(yaml.utf8).write(to: url) // non-atomic: truncate + write
            #expect(await eventually { store.library.groups.first?.snippets.first?.keyword == ";b" })
        }
    }

    @Test func unreadableFileIsNeverOverwritten() async throws {
        try await withTempDir { dir in
            let url = dir.appending(path: "snippets.yaml")
            let original = Data(SnippetYAML.encode(SnippetLibrary(groups: [group(";a")])).utf8)
            try original.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
            let store = SnippetStore(fileURL: url)
            store.load()
            #expect(store.loadError != nil)
            #expect(throws: StoreError.fileUnreadable) { try store.update { $0.groups.append(group(";b")) } }
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test func updateReloadsExternalEditFirst() async throws {
        try await withTempDir { dir in
            let url = dir.appending(path: "snippets.yaml")
            let store = SnippetStore(fileURL: url)
            try store.update { $0.groups.append(group(";a")) }
            let external = SnippetYAML.encode(SnippetLibrary(groups: [group(";x")]))
            try Data(external.utf8).write(to: url, options: .atomic)
            try store.update { $0.groups.append(group(";b")) }
            let keywords = store.library.groups.flatMap(\.snippets).map(\.keyword)
            #expect(keywords == [";x", ";b"])
            let other = SnippetStore(fileURL: url)
            other.load()
            #expect(other.library.groups.flatMap(\.snippets).map(\.keyword) == [";x", ";b"])
        }
    }
}
