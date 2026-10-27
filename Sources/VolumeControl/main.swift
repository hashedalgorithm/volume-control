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

/// A second launch (double-click, `open` while one's already running, a dev-cycle
/// mistake) must not proceed: two instances would both bind the same HAL devices and
/// both run their own AVAudioEngine instances concurrently, competing for the same
/// real-time audio thread -- confirmed directly causing audible output glitching
/// during a live call once just two of this app's *own* engines (input-mix's +
/// mic-capture's) were left running at the same time, let alone two whole duplicate
/// processes. Checked by PID rather than count, since this process may not have
/// registered itself with Launch Services yet at this early point -- an empty result
/// here would wrongly look like "no others running" if it included an unregistered
/// self by miscounting rather than by PID.
private func quitIfAnotherInstanceIsRunning() {
    let bundleID = Bundle.main.bundleIdentifier ?? "com.volumecontrol.app"
    let myPID = ProcessInfo.processInfo.processIdentifier
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != myPID }
    guard let existing = others.first else { return }
    existing.activate()
    exit(0)
}

@available(macOS 14.2, *)
func runApp() {
    quitIfAnotherInstanceIsRunning()
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory) // menu-bar-only, no Dock icon
    let controller = PopoverController()
    appControllerBox = controller
    // NSApplication.delegate is weak -- appControllerBox above is what actually keeps
    // the controller alive; this just lets applicationShouldTerminate (PopoverController's
    // real teardown path, see its own comment) receive the notification.
    app.delegate = controller
    app.run()
}

if #available(macOS 14.2, *) {
    runApp()
} else {
    fputs("Volume Control requires macOS 14.2 or later (CoreAudio process-tap API).\n", stderr)
    exit(1)
}
