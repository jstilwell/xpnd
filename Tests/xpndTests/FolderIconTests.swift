import AppKit
import Testing
@testable import xpnd

struct FolderIconTests {
    @Test func roundTripsThroughYAML() throws {
        let inner = ConnectionFolder(name: "inner")
        let lib = ConnectionLibrary(folders: [ConnectionFolder(name: "win", folders: [inner], icon: .windows)])
        let back = try ConnectionYAML.decode(ConnectionYAML.encode(lib))
        #expect(back.folders[0].icon == .windows)
        #expect(back.folders[0].folders[0].icon == nil)
        #expect(back == lib)
    }

    @Test func oldFileLoadsWithNil() throws {
        let lib = try ConnectionYAML.decode("folders:\n  - name: x\n")
        #expect(lib.folders[0].icon == nil)
    }

    @Test func unknownIconDecodesAsNilAndKeepsTheFolder() throws {
        let lib = try ConnectionYAML.decode("folders:\n  - name: x\n    icon: spaceship\n    color: blue\n    activation: \"\"\n")
        #expect(lib.folders[0].icon == nil)
        #expect(lib.folders[0].color == .blue)
        #expect(lib.folders[0].activation == "")
    }

    @Test func iconIsWrittenOnlyWhenSet() {
        let plain = ConnectionYAML.encode(ConnectionLibrary(folders: [ConnectionFolder(name: "f")]))
        #expect(!plain.contains("icon"))
        let set = ConnectionYAML.encode(ConnectionLibrary(folders: [ConnectionFolder(name: "f", icon: .server)]))
        #expect(set.contains("icon: server"))
    }

    @Test func everyCaseHasASymbolAndLabelAndTheyAreUnique() {
        let cases = FolderIcon.allCases
        #expect(cases.count == 9)
        #expect(cases.allSatisfy { !$0.symbolName.isEmpty && !$0.label.isEmpty })
        #expect(Set(cases.map(\.symbolName)).count == cases.count)
        #expect(Set(cases.map(\.label)).count == cases.count)
        for icon in cases {
            #expect(NSImage(systemSymbolName: icon.symbolName, accessibilityDescription: nil) != nil, "\(icon.symbolName)")
        }
    }

    @Test func nilIconIsThePlainFolder() {
        let none: FolderIcon? = nil
        #expect(none.symbol == "folder")
        #expect(Optional(FolderIcon.windows).symbol == "pc")
    }

    @Test func subfoldersDoNotInherit() {
        let sub = ConnectionFolder(name: "sub")
        let root = ConnectionFolder(name: "root", folders: [sub], icon: .cloud)
        let model = QuickMenuModel(library: ConnectionLibrary(folders: [root]), folder: root.id)
        #expect(model.rows.map(\.icon) == [nil])
        let rows = ConnectionTreeRow.rows(ConnectionLibrary(folders: [root]), expanded: [root.id])
        #expect(rows.map(\.icon) == [.cloud, nil])
    }
}
