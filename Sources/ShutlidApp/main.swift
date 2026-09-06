import AppKit

// Menu-bar only: no Dock icon, no main window. The delegate is kept alive here for the life of the process.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
