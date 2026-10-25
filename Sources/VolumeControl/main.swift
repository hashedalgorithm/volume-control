import AppKit

/// Holding PopoverController only as a local inside runApp() let a release
/// (-O) build's ARC optimizer deallocate it right after its last textual use --
/// nothing after that point referenced it, since app.run() doesn't touch it --
/// which left NSStatusItem's (weak) button.target dangling: clicks still logged
/// via AppKit's internal tracking, but never reached a live object, so the
/// panel never opened. A debug (-Onone) build happened to keep it alive for
/// the whole scope, which is why this only showed up in the shipped DMG.
/// Stashing it in this untyped top-level global (can't be `@available` itself --
/// main.swift is script-mode -- so it's typed `Any?` rather than
/// `PopoverController?`) gives it program-lifetime retention, immune to that
/// optimization.
private var appControllerBox: Any?

@available(macOS 14.2, *)
func runApp() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory) // menu-bar-only, no Dock icon
    appControllerBox = PopoverController()
    app.run()
}

if #available(macOS 14.2, *) {
    runApp()
} else {
    fputs("Volume Control requires macOS 14.2 or later (CoreAudio process-tap API).\n", stderr)
    exit(1)
}
