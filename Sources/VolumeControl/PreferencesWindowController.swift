import AppKit
import SwiftUI

/// A normal titled NSWindow (not the borderless AnchoredPanel the main popover uses)
/// hosting PreferencesView -- standard window chrome, traffic lights, draggable,
/// resizable-off, matching ordinary macOS Preferences windows rather than the
/// menu-bar-anchored panel.
@available(macOS 14.2, *)
final class PreferencesWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: PreferencesView())
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "Volume Control Preferences"
        newWindow.styleMask = [.titled, .closable]
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        newWindow.center()
        window = newWindow

        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
