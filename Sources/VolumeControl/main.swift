import AppKit

@available(macOS 14.2, *)
func runApp() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory) // menu-bar-only, no Dock icon
    let controller = MenuBarController()
    _ = controller
    app.run()
}

if #available(macOS 14.2, *) {
    runApp()
} else {
    fputs("Volume Control requires macOS 14.2 or later (CoreAudio process-tap API).\n", stderr)
    exit(1)
}
