import AppKit

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
// Menu-bar only until the main window opens, so a login-item launch never flashes a Dock icon.
app.setActivationPolicy(.accessory)
app.run()
