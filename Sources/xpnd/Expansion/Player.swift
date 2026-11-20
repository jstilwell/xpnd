@MainActor struct Player {
    let sender: any KeystrokeSending
    let actions: any ActionRunning

    /// Deletes the typed keyword, then plays each step in order. A missing app or Shortcut throws before the
    /// keyword is deleted; any other action's error stops playback where it is.
    /// `tail`, read once just before the delete: text to type after the expansion's text, and how many of
    /// those characters were typed into the app since the keyword (so they're deleted too).
    func play(
        _ steps: [PlayStep], deletingCharacters: Int,
        tail: @MainActor () -> (text: String, typedSince: Int) = { ("", 0) }
    ) async throws(ExpansionError) {
        try await actions.check(steps)
        let tail = tail()
        let deleting = deletingCharacters + tail.typedSince
        if deleting > 0 { await sender.backspace(times: deleting) }
        for step in steps.appendingText(tail.text) {
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
