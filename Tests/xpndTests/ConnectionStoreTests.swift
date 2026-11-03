import Foundation
import Testing
@testable import xpnd

@MainActor
private func withTemp(_ body: (URL, UserDefaults) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let suite = UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suite)
    }
    try body(dir.appending(path: "connections.yaml"), defaults)
}

@MainActor
struct ConnectionStoreTests {
    @Test func seedsOnceOnFirstLaunch() throws {
        try withTemp { url, defaults in
            let store = ConnectionStore(fileURL: url)
            store.seedIfFirstLaunch(defaults: defaults)
            store.load()
            #expect(store.library.folders.map(\.name) == ["dev", "prod"])
            #expect(defaults.bool(forKey: "connectionsSeeded"))
            try FileManager.default.removeItem(at: url)
            store.seedIfFirstLaunch(defaults: defaults)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func doesNotSeedOverExistingFile() throws {
        try withTemp { url, defaults in
            let store = ConnectionStore(fileURL: url)
            try store.update { $0.folders = [ConnectionFolder(name: "mine")] }
            store.seedIfFirstLaunch(defaults: defaults)
            store.load()
            #expect(store.library.folders.map(\.name) == ["mine"])
            #expect(defaults.bool(forKey: "connectionsSeeded"))
        }
    }

    @Test func storeRoundTrip() throws {
        try withTemp { url, _ in
            let c = Connection(name: "web", host: "h", activation: ";w")
            let lib = ConnectionLibrary(folders: [ConnectionFolder(name: "f", connections: [c])])
            try ConnectionStore(fileURL: url).update { $0 = lib }
            let other = ConnectionStore(fileURL: url)
            other.load()
            #expect(other.library == lib)
        }
    }

    @Test func duplicateActivationRefused() throws {
        try withTemp { url, _ in
            let store = ConnectionStore(fileURL: url)
            #expect(throws: StoreError.duplicateKeyword(";x")) {
                try store.update {
                    $0.folders = [ConnectionFolder(name: "f", activation: ";x",
                                                   connections: [Connection(name: "a", host: "h", activation: ";x")])]
                }
            }
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func malformedNeverOverwritten() throws {
        try withTemp { url, _ in
            try Data("folders: [".utf8).write(to: url)
            let store = ConnectionStore(fileURL: url)
            store.load()
            #expect(store.loadError != nil)
            #expect(throws: StoreError.fileUnreadable) { try store.update { $0 = .starter() } }
            #expect(try String(contentsOf: url, encoding: .utf8) == "folders: [")
        }
    }
}
