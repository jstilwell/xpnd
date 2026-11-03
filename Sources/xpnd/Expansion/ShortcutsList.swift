import Foundation

enum ShortcutsList {
    static func parse(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func fetch() async -> [String] {
        guard let r = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/shortcuts"), arguments: ["list"], timeoutMs: 10_000),
              r.status == 0 else { return [] }
        return parse(r.stdout)
    }
}
