import Testing
@testable import xpnd

struct QuickMenuModelTests {
    private func conn(_ name: String) -> Connection { Connection(name: name, host: name + ".example.com") }

    @Test func numbersFirstNine() {
        let sub = ConnectionFolder(name: "sub")
        let root = ConnectionFolder(name: "prod", connections: (1...10).map { conn("c\($0)") }, folders: [sub])
        let model = QuickMenuModel(library: ConnectionLibrary(folders: [root]), folder: root.id)
        #expect(model.rows.count == 11)
        #expect(model.rows.map(\.number) == Array(1...9).map { Optional($0) } + [nil, nil])
        #expect(model.rows[0].title == "c1")
        #expect(model.rows[10].kind == .folder(sub.id))
        #expect(model.row(number: 10) == nil)
    }

    @Test func digitPicks() {
        let a = conn("a"), b = conn("b")
        let root = ConnectionFolder(name: "prod", connections: [a, b])
        var model = QuickMenuModel(library: ConnectionLibrary(folders: [root]), folder: root.id)
        #expect(model.row(number: 0) == nil)
        #expect(model.row(number: 3) == nil)
        let row = try! #require(model.row(number: 2))
        #expect(row.kind == .connection(b.id, .ssh))
        #expect(model.choose(row) == b.id)
    }

    @Test func subfolderAndBack() {
        let inner = conn("inner")
        let sub = ConnectionFolder(name: "sub", connections: [inner])
        let root = ConnectionFolder(name: "prod", connections: [conn("a")], folders: [sub])
        var model = QuickMenuModel(library: ConnectionLibrary(folders: [root]), folder: root.id)
        #expect(!model.canGoBack)
        #expect(model.choose(model.row(number: 2)!) == nil)
        #expect(model.title == "sub")
        #expect(model.canGoBack)
        #expect(model.rows.map(\.title) == ["inner"])
        model.back()
        #expect(model.title == "prod")
        #expect(!model.canGoBack)
        model.back()
        #expect(model.title == "prod")
    }

    @Test func emptyFolder() {
        let root = ConnectionFolder(name: "prod")
        let model = QuickMenuModel(library: ConnectionLibrary(folders: [root]), folder: root.id)
        #expect(model.rows.isEmpty)
        #expect(model.title == "prod")
    }

    @Test func staleFolderIsEmpty() {
        let model = QuickMenuModel(library: .empty, folder: ConnectionFolder(name: "gone").id)
        #expect(model.rows.isEmpty)
        #expect(!model.title.isEmpty)
    }
}
