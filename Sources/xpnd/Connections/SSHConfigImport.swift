import Foundation

/// Reads `~/.ssh/config` into connections for the import preview. Text only: never `ssh -G`, nothing is run.
/// `Include` and `Match` are skipped (the notes say so), as are `Host` entries that are only patterns.
enum SSHConfigImport {
    static let folderName = "SSH config"

    private struct Block {
        let name: String
        var values: [String: String] = [:]
    }

    /// One folder of connections, one per `Host` block, and notes for the preview about what was left out. A host
    /// with the same name and address as one in `existing` is skipped, so importing again adds only what's new.
    static func parse(_ text: String, existing: ConnectionLibrary = .empty) -> (library: ConnectionLibrary, notes: [String]) {
        var blocks: [Block] = []
        var current: Int? // the block that lines go to; nil before the first Host and inside Match
        var patterns = 0, sawInclude = false, sawMatch = false
        var notes: [String] = []
        let wanted: Set<String> = ["hostname", "user", "port", "identityfile", "proxyjump"]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let (keyword, value) = split(line)
            switch keyword {
            case "host":
                let names = value.split(whereSeparator: \.isWhitespace).map(String.init)
                if let name = names.first(where: { !$0.contains(where: "*?!".contains) }) {
                    blocks.append(Block(name: name))
                    current = blocks.count - 1
                } else {
                    patterns += 1
                    current = nil
                }
            case "match":
                sawMatch = true
                current = nil
            case "include":
                sawInclude = true
            default:
                // ssh keeps the first value it reads for an option.
                guard let index = current, wanted.contains(keyword), blocks[index].values[keyword] == nil else { continue }
                guard !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                    notes.append("Skipped a \(display(keyword)) for \(blocks[index].name): it has a control character.")
                    blocks[index].values[keyword] = ""
                    continue
                }
                blocks[index].values[keyword] = value
            }
        }
        if patterns > 0 {
            let entries = patterns == 1 ? "1 Host entry" : "\(patterns) Host entries"
            notes.insert("Skipped \(entries) that are patterns (*, ? or !).", at: 0)
        }
        if sawInclude { notes.append("Include lines were ignored.") }
        if sawMatch { notes.append("Match blocks were ignored.") }
        let have = Set(existing.allConnections.map { [$0.name, $0.host] })
        let parsed = blocks.map { block in
            func value(_ key: String) -> String? { block.values[key].flatMap { $0.isEmpty ? nil : $0 } }
            var port: Int?
            if let text = value("port") {
                if let n = Int(text), (1...65535).contains(n) { port = n } else {
                    notes.append("Skipped Port “\(text)” for \(block.name): it isn't a port number.")
                }
            }
            let jump = value("proxyjump").flatMap { $0.lowercased() == "none" ? nil : JumpHost.text($0) }
            return Connection(name: block.name, host: value("hostname") ?? block.name, port: port, username: value("user"),
                              jumpHost: jump, sshOptions: value("identityfile").map { "-i " + ShellQuote.quote($0) } ?? "")
        }
        let connections = parsed.filter { !have.contains([$0.name, $0.host]) }
        if parsed.count > connections.count {
            let n = parsed.count - connections.count
            notes.append("Skipped \(n == 1 ? "1 host" : "\(n) hosts") already in your connections.")
        }
        return (ConnectionLibrary(folders: [ConnectionFolder(name: folderName, connections: connections)]), notes)
    }

    /// `Keyword value`, `Keyword=value` or `Keyword = value`; the keyword lowercased, one pair of quotes taken off.
    private static func split(_ line: String) -> (String, String) {
        let end = line.firstIndex { $0.isWhitespace || $0 == "=" } ?? line.endIndex
        var rest = line[end...].drop(while: \.isWhitespace)
        if rest.first == "=" { rest = rest.dropFirst().drop(while: \.isWhitespace) }
        var value = String(rest).trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
        return (line[..<end].lowercased(), value)
    }

    private static func display(_ keyword: String) -> String {
        ["hostname": "HostName", "user": "User", "port": "Port", "identityfile": "IdentityFile", "proxyjump": "ProxyJump"][keyword] ?? keyword
    }
}
