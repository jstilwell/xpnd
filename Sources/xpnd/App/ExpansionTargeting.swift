/// Keys aimed at xpnd reset the buffer, except in a focused built-in terminal, which expands like any app.
enum ExpansionTargeting {
    static func targetsXpnd(keyTargetsProcess: Bool, terminalFocused: Bool) -> Bool {
        keyTargetsProcess && !terminalFocused
    }
}
