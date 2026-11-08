import Foundation

/// A field the sidebar's Rename and Set Activation… ask the Details editor to focus.
enum EditorFocus: Hashable {
    case name, activation
}

extension StoreError {
    var connectionsMessage: String {
        switch self {
        case .fileUnreadable: "Couldn't save connections.yaml."
        case .duplicateKeyword(let string): "“\(string)” is already used by another connection or folder."
        case .encodingFailed: "Couldn't write the connections as YAML, so nothing was saved."
        }
    }
}

/// The editors' rules that don't need a view.
enum EditorRules {
    /// Where a drop between rows of a folder (or group) list lands when the dragged item can't sit
    /// among them: the folder above the insertion line. Above the first row that is the enclosing
    /// folder, or at the top level the first folder.
    static func aboveTheLine<ID>(index: Int, siblings: [ID], container: ID?) -> ID? {
        if index > 0 { return siblings[min(index, siblings.count) - 1] }
        return container ?? siblings.first
    }

    /// The folder the sidebar's "+" adds into: the selected folder, or a selected connection's. nil
    /// means the top level (or that nothing relevant is selected).
    static func addTarget(for selection: SidebarItem?, in library: ConnectionLibrary) -> ConnectionFolder.ID? {
        switch selection {
        case .folder(let id)?: library.folder(id)?.id
        case .connection(let id)?: library.path(of: id).last?.id
        default: nil
        }
    }

    /// `base`, else `base 2`, `base 3`… whichever is free first.
    static func uniqueName(_ base: String, taken: Set<String>) -> String {
        (1...).lazy.map { $0 == 1 ? base : "\(base) \($0)" }.first { !taken.contains($0) } ?? base
    }

    /// The `port` to store: nil when empty or the type's default.
    static func parsePort(_ text: String, type: ConnectionType) -> (port: Int?, problem: String?) {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return (nil, nil) }
        guard let port = Int(text) else { return (nil, "The port must be a number.") }
        guard (1...65535).contains(port) else { return (nil, "The port must be between 1 and 65535.") }
        return (port == type.defaultPort ? nil : port, nil)
    }

    /// "1 connection", "2 connections".
    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    /// "From folder prod: prod-ssh (1Password)", or "Not set".
    static func summary(_ resolved: ResolvedCredential?) -> String {
        guard let resolved else { return "Not set" }
        let provider = switch resolved.ref.provider {
        case "1password": "1Password"
        case KeychainProvider.id: "Keychain"
        default: resolved.ref.provider
        }
        let item = "\(resolved.ref.title) (\(provider))"
        return switch resolved.source {
        case .connection: item
        case .folder(let name): "From folder \(name): \(item)"
        case .global: "Global: \(item)"
        case .login: "From login credential: \(item)"
        }
    }

    /// Why `jump` can't be `id`'s jump host, or nil if it can.
    static func jumpHostProblem(_ jump: Connection.ID, for id: Connection.ID, in library: ConnectionLibrary) -> String? {
        guard library.connection(jump) != nil else { return SSHCommandError.jumpHostMissing.message }
        guard library.loginCredential(for: jump)?.ref.category == .sshKey else { return "Jump hosts must use an SSH key" }
        var candidate = library
        candidate.editConnection(id) { $0.jumpHost = .connection(jump) }
        do throws(SSHCommandError) {
            // Only builds argv; nothing is read from the keys directory.
            _ = try SSHCommandBuilder.build(id, in: candidate, keysDirectory: URL(filePath: "/"))
        } catch .jumpHostCycle {
            return SSHCommandError.jumpHostCycle.message
        } catch .jumpHostChainTooLong {
            return SSHCommandError.jumpHostChainTooLong.message
        } catch {
            // Other problems (an unmatched quote in the options, say) aren't the jump host's.
        }
        return nil
    }
}

extension ConnectionFolder {
    fileprivate func folderPath(of id: ID) -> [ConnectionFolder]? {
        if self.id == id { return [self] }
        return folders.lazy.compactMap { $0.folderPath(of: id) }.first.map { [self] + $0 }
    }

    fileprivate mutating func editFolder(_ id: ID, _ change: (inout ConnectionFolder) -> Void) -> Bool {
        if self.id == id {
            change(&self)
            return true
        }
        for index in folders.indices where folders[index].editFolder(id, change) { return true }
        return false
    }

    fileprivate mutating func refreshRefs(_ fresh: CredentialRef) {
        fresh.refresh(&credential)
        fresh.refresh(&sudoCredential)
        for index in connections.indices {
            fresh.refresh(&connections[index].credential)
            fresh.refresh(&connections[index].sudoCredential)
        }
        for index in folders.indices { folders[index].refreshRefs(fresh) }
    }
}

extension CredentialRef {
    /// Replaces `stored` with self when both name the same 1Password item.
    fileprivate func refresh(_ stored: inout CredentialRef?) {
        if let old = stored, old.provider == provider, old.account == account, old.item == item { stored = self }
    }
}

extension ConnectionLibrary {
    /// The folder and its ancestors, from the root; empty if it isn't in the tree.
    func folderPath(of id: ConnectionFolder.ID) -> [ConnectionFolder] {
        folders.lazy.compactMap { $0.folderPath(of: id) }.first ?? []
    }

    func folder(atNamePath names: [String]) -> ConnectionFolder? {
        var level = folders
        var found: ConnectionFolder?
        for name in names {
            guard let next = level.first(where: { $0.name == name }) else { return nil }
            found = next
            level = next.folders
        }
        return found
    }

    func connection(atNamePath names: [String]) -> Connection? {
        guard let name = names.last else { return nil }
        return folder(atNamePath: names.dropLast()).flatMap { $0.connections.first { $0.name == name } }
    }

    /// Folder names from the root, then the connection's name, so a reload that changed ids can find it again.
    func namePath(of item: SidebarItem) -> [String]? {
        switch item {
        case .folder(let id): folder(id).map { _ in folderPath(of: id).map(\.name) }
        case .connection(let id): connection(id).map { path(of: id).map(\.name) + [$0.name] }
        default: nil
        }
    }

    /// A folder's own credential (source `.connection`: the item's own), else the nearest ancestor's, else global.
    func folderLoginCredential(for id: ConnectionFolder.ID) -> ResolvedCredential? {
        resolveFolder(id, \.credential, global: credential)
    }

    /// As `sudoCredential(for:)`, for a folder.
    func folderSudoCredential(for id: ConnectionFolder.ID) -> ResolvedCredential? {
        if let sudo = resolveFolder(id, \.sudoCredential, global: sudoCredential) { return sudo }
        guard sudoUsesLogin, let login = folderLoginCredential(for: id), login.ref.hasPassword else { return nil }
        return ResolvedCredential(ref: login.ref, source: .login)
    }

    private func resolveFolder(
        _ id: ConnectionFolder.ID, _ key: KeyPath<ConnectionFolder, CredentialRef?>, global: CredentialRef?
    ) -> ResolvedCredential? {
        let path = folderPath(of: id)
        guard let own = path.last else { return nil }
        if let ref = own[keyPath: key] { return ResolvedCredential(ref: ref, source: .connection) }
        for folder in path.dropLast().reversed() {
            if let ref = folder[keyPath: key] { return ResolvedCredential(ref: ref, source: .folder(name: folder.name)) }
        }
        return global.map { ResolvedCredential(ref: $0, source: .global) }
    }

    @discardableResult
    mutating func editFolder(_ id: ConnectionFolder.ID, _ change: (inout ConnectionFolder) -> Void) -> Bool {
        for index in folders.indices where folders[index].editFolder(id, change) { return true }
        return false
    }

    @discardableResult
    mutating func editConnection(_ id: Connection.ID, _ change: (inout Connection) -> Void) -> Bool {
        guard let parent = path(of: id).last?.id else { return false }
        return editFolder(parent) { folder in
            if let index = folder.connections.firstIndex(where: { $0.id == id }) { change(&folder.connections[index]) }
        }
    }

    /// Every stored copy of the same item, at any level, takes `fresh`'s title, category and username.
    mutating func refreshRefs(_ fresh: CredentialRef) {
        fresh.refresh(&credential)
        fresh.refresh(&sudoCredential)
        for index in folders.indices { folders[index].refreshRefs(fresh) }
    }

    /// Where `item` can move: any folder outside its own subtree, other than the one it's in.
    func moveTargets(for item: SidebarItem) -> [ConnectionFolder] {
        let excluded: Set<ConnectionFolder.ID>
        switch item {
        case .folder(let id):
            guard let folder = folder(id) else { return [] }
            excluded = Set(folderPath(of: id).dropLast().suffix(1).map(\.id) + folder.allFolders.map(\.id))
        case .connection(let id):
            excluded = Set(path(of: id).suffix(1).map(\.id))
        default:
            return []
        }
        return allFolders.filter { !excluded.contains($0.id) }
    }

    /// Moves `item` into `destination` (nil: the top level, for folders). `at`: its position among
    /// the siblings of its kind, counted before it is taken out, as a drop between rows reports it;
    /// nil appends. False, and no change, if either is gone or the folder would go into its own subtree.
    @discardableResult
    mutating func move(_ item: SidebarItem, to destination: ConnectionFolder.ID?, at: Int? = nil) -> Bool {
        let from: ConnectionFolder.ID?
        let fromIndex: Int
        switch item {
        case .folder(let id):
            let path = folderPath(of: id)
            guard let own = path.last else { return false }
            from = path.dropLast().last?.id
            fromIndex = (from.flatMap(folder) ?? self.asRoot).folders.firstIndex { $0.id == id } ?? 0
            if let destination, own.allFolders.contains(where: { $0.id == destination }) { return false }
        case .connection(let id):
            guard let parent = path(of: id).last else { return false }
            from = parent.id
            fromIndex = parent.connections.firstIndex { $0.id == id } ?? 0
            guard destination != nil else { return false }
        default:
            return false
        }
        if let destination, folder(destination) == nil { return false }
        guard from != destination || at != nil else { return false }
        // A drop index counts the item itself when it moves later in the same list.
        let index = at.map { from == destination && fromIndex < $0 ? $0 - 1 : $0 }

        var next = self
        guard let moved = next.remove(item) else { return false }
        func place<T>(_ element: T, in array: inout [T]) {
            array.insert(element, at: min(index ?? array.count, array.count))
        }
        switch (moved, destination) {
        case (.folder(let f), nil): place(f, in: &next.folders)
        case (.folder(let f), let target?): guard next.editFolder(target, { place(f, in: &$0.folders) }) else { return false }
        case (.connection(let c), let target?): guard next.editFolder(target, { place(c, in: &$0.connections) }) else { return false }
        case (.connection, nil): return false
        }
        self = next
        return true
    }

    /// The top level, shaped like a folder, so top-level and nested moves share one path.
    private var asRoot: ConnectionFolder { ConnectionFolder(name: "", connections: [], folders: folders) }

    enum Removed {
        case folder(ConnectionFolder), connection(Connection)
    }

    @discardableResult
    mutating func remove(_ item: SidebarItem) -> Removed? {
        var removed: Removed?
        switch item {
        case .folder(let id):
            if let index = folders.firstIndex(where: { $0.id == id }) { return .folder(folders.remove(at: index)) }
            guard let parent = folderPath(of: id).dropLast().last?.id else { return nil }
            editFolder(parent) { folder in
                if let index = folder.folders.firstIndex(where: { $0.id == id }) { removed = .folder(folder.folders.remove(at: index)) }
            }
        case .connection(let id):
            guard let parent = path(of: id).last?.id else { return nil }
            editFolder(parent) { folder in
                if let index = folder.connections.firstIndex(where: { $0.id == id }) {
                    removed = .connection(folder.connections.remove(at: index))
                }
            }
        default:
            return nil
        }
        return removed
    }
}

/// Connection saving for the main window's sidebar and Details pane. Every edit saves at once
/// through `store.update`; ids are persisted, so a save finds its item by id.
@MainActor @Observable
final class ConnectionEditing {
    let store: ConnectionStore
    let snippets: SnippetStore
    /// Asked at each use, so a changed op path in Settings applies at once.
    private let currentProvider: @MainActor () -> any CredentialProvider
    /// Settings' chosen account id, if any.
    private let preferredAccount: @MainActor () -> String?
    let keysDirectory: URL
    let connect: (Connection.ID, _ sudo: Bool) -> Void
    /// Ends the connection's running session (after asking), and brings its tab forward.
    let disconnect: (Connection.ID) -> Void
    let showSession: (Connection.ID) -> Void
    var saveProblem: String?

    init(store: ConnectionStore, snippets: SnippetStore, provider: @escaping @MainActor () -> any CredentialProvider,
         preferredAccount: @escaping @MainActor () -> String? = { nil }, keysDirectory: URL,
         connect: @escaping (Connection.ID, _ sudo: Bool) -> Void,
         disconnect: @escaping (Connection.ID) -> Void = { _ in }, showSession: @escaping (Connection.ID) -> Void = { _ in }) {
        self.store = store
        self.snippets = snippets
        self.currentProvider = provider
        self.preferredAccount = preferredAccount
        self.keysDirectory = keysDirectory
        self.connect = connect
        self.disconnect = disconnect
        self.showSession = showSession
    }

    var provider: any CredentialProvider { currentProvider() }
    /// Settings picked the macOS Keychain for new credentials.
    var usesKeychain: Bool { preferredAccount() == KeychainProvider.id }

    var library: ConnectionLibrary { store.library }
    var readOnly: Bool { store.loadError != nil }
    /// Uniqueness across both files, from the other file's last good contents.
    var namespace: KeywordNamespace { KeywordNamespace(snippets: snippets.library, connections: store.library) }

    /// `change` returns false if its item is gone.
    @discardableResult
    func save(_ change: (inout ConnectionLibrary) -> Bool) -> Bool {
        var found = false
        do {
            try store.update { found = change(&$0) }
        } catch {
            saveProblem = error.connectionsMessage
            return false
        }
        saveProblem = found ? nil : "That item changed in connections.yaml. Select it again."
        return found
    }

    @discardableResult
    func edit(folder id: ConnectionFolder.ID, _ change: (inout ConnectionFolder) -> Void) -> Bool {
        save { $0.editFolder(id, change) }
    }

    @discardableResult
    func edit(connection id: Connection.ID, _ change: (inout Connection) -> Void) -> Bool {
        save { $0.editConnection(id, change) }
    }

    /// The notch's "Set as this connection's default". A tab can outlive its connection, which is then left alone.
    func saveDisplay(_ id: Connection.ID, _ display: RDPOptions.Display) -> Bool {
        guard library.connection(id) != nil else { return false }
        return edit(connection: id) {
            var options = $0.rdp ?? RDPOptions()
            options.display = display
            $0.rdp = options
        }
    }

    /// The new connection's id, or nil if it wasn't saved.
    func addConnection(in folder: ConnectionFolder.ID) -> Connection.ID? {
        let new = Connection(name: EditorRules.uniqueName("New Connection", taken: Set(library.allConnections.map(\.name))), host: "")
        return edit(folder: folder) { $0.connections.append(new) } ? new.id : nil
    }

    /// Unique across the tree, so the new folder's derived activation string isn't contested.
    func addFolder(in parent: ConnectionFolder.ID?) -> ConnectionFolder.ID? {
        let new = ConnectionFolder(name: EditorRules.uniqueName("New Folder", taken: Set(library.allFolders.map(\.name))))
        guard let parent else { return save { $0.folders.append(new); return true } ? new.id : nil }
        return edit(folder: parent) { $0.folders.append(new) } ? new.id : nil
    }

    /// A copy just after the original, without its activation string (which must stay unique).
    func duplicate(_ id: Connection.ID) -> Connection.ID? {
        guard let original = library.connection(id), let parent = library.path(of: id).last?.id else { return nil }
        var copy = original
        copy.id = UUID()
        copy.name = EditorRules.uniqueName(original.name, taken: Set(library.allConnections.map(\.name)))
        copy.activation = nil
        return edit(folder: parent) { folder in
            let index = folder.connections.firstIndex { $0.id == id }.map { $0 + 1 } ?? folder.connections.endIndex
            folder.connections.insert(copy, at: index)
        } ? copy.id : nil
    }

    func move(_ item: SidebarItem, to destination: ConnectionFolder.ID?, at index: Int? = nil) -> Bool {
        save { $0.move(item, to: destination, at: index) }
    }

    func delete(_ item: SidebarItem) -> Bool {
        save { $0.remove(item) != nil }
    }

    /// The account to search: the one chosen in Settings, or the only one. Never a guess.
    func account() async throws(CredentialError) -> String {
        let preferred = preferredAccount()
        switch await provider.status(account: preferred) {
        case .notInstalled: throw .notInstalled
        case .notSignedIn(let message): throw .failed(message)
        case .chooseAccount: throw .failed("Choose your 1Password account in Settings → Password Manager.")
        case .ready(let accounts):
            guard let account = accounts.first(where: { $0.id == preferred }) ?? (accounts.count == 1 ? accounts.first : nil)
            else { throw .locked }
            return account.id
        }
    }

    /// The ref to store for a picked item, after saving an SSH key's public key. nil if the task
    /// was cancelled meanwhile (the sheet closed), so a cancelled pick never lands in a slot.
    func pick(_ item: CredentialItem, account: String) async throws(CredentialError) -> CredentialRef? {
        // Refs end up in argv and, for keys, a file name.
        guard CredentialRef.isSafe(item.id), CredentialRef.isSafe(item.vaultID) else { throw .invalidRef }
        let ref = item.ref(account: account)
        if ref.category == .sshKey { try await savePublicKey(for: ref) }
        return Task.isCancelled ? nil : ref
    }

    /// Fetches an SSH key item's public key into `keys/<item>.pub`.
    func savePublicKey(for ref: CredentialRef) async throws(CredentialError) {
        // The item id names a file, so it must not leave the keys directory.
        guard CredentialRef.isSafe(ref.item) else { throw .invalidRef }
        let key = try await provider.publicKey(for: ref)
        do {
            try SSHCommandBuilder.writeKeyFile(key, for: ref, in: keysDirectory)
        } catch {
            throw .failed("xpnd couldn't save the public key for “\(ref.title)”.")
        }
    }

    /// Re-reads the item's title, category and username (and an SSH key's public key) and updates
    /// every stored copy. `op item list` has no lookup by id, so this lists the account and matches it.
    func refresh(_ ref: CredentialRef) async throws(CredentialError) {
        guard let item = try await provider.search("", account: ref.account).first(where: { $0.id == ref.item }) else {
            throw .notFound(ref.title)
        }
        let fresh = item.ref(account: ref.account)
        if fresh.category == .sshKey { try await savePublicKey(for: fresh) }
        if !save({ $0.refreshRefs(fresh); return true }) { throw .failed(saveProblem ?? "Couldn't save connections.yaml.") }
    }
}
