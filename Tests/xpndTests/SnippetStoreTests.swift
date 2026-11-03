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
}
