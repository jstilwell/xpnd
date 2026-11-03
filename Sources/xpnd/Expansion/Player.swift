@MainActor struct Player {
    let sender: any KeystrokeSending
    let actions: any ActionRunning

    /// Deletes the typed keyword, then plays each step in order. An action's error stops playback.
    func play(_ steps: [PlayStep], deletingCharacters: Int) async throws(ExpansionError) {
        if deletingCharacters > 0 { await sender.backspace(times: deletingCharacters) }
        for step in steps {
            switch step {
            case .paste(let text): await sender.paste(text)
            case .key(let key, let count): await sender.press(key, times: count)
            case .shortcut(let combo): await sender.press(combo)
            case .delay(let ms): try? await Task.sleep(for: .milliseconds(ms))
            case .openApp(let path): try await actions.openApp(path: path)
            case .runShortcut(let name): try await actions.runShortcut(name: name)
            case .moveLeft(let n): await sender.press(.left, times: n)
            }
        }
    }
}
