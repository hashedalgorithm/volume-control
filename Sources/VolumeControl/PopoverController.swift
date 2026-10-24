import AppKit
import SwiftUI

/// A borderless panel that always anchors its top edge just below the status item and
/// grows/shrinks height downward only, never repositioning itself vertically. Replaces
/// an earlier `NSPopover`-based implementation: `NSPopover` automatically repositions
/// (including upward, off the top of the screen) whenever its content grows too tall
/// to fit below the anchor before the screen edge -- that's by-design AppKit behavior,
/// not something a flag disables, and it's what made the panel drift and become
/// unreachable once enough app rows were showing.
@available(macOS 14.2, *)
private final class AnchoredPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@available(macOS 14.2, *)
final class PopoverController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model = AudioMixerModel()
    private let hostingController: NSHostingController<MixerPanelView>
    private let panel: AnchoredPanel
    private var outsideClickMonitor: Any?
    private var keyDownMonitor: Any?
    private var frameObserver: NSObjectProtocol?

    override init() {
        let rootView = MixerPanelView(model: model, onQuit: {})
        hostingController = NSHostingController(rootView: rootView)
        panel = AnchoredPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        hostingController.rootView = MixerPanelView(model: model, onQuit: { [weak self] in self?.quit() })

        panel.contentViewController = hostingController
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        statusItem.button?.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Volume Control")
        statusItem.button?.action = #selector(toggle)
        statusItem.button?.target = self

        hostingController.view.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: hostingController.view, queue: .main
        ) { [weak self] _ in
            self?.reposition()
        }
    }

    @objc private func toggle() {
        if panel.isVisible {
            close()
        } else {
            model.refresh()
            reposition()
            panel.makeKeyAndOrderFront(nil)
            startOutsideDismissMonitors()
        }
    }

    /// Recomputes content size and repositions so the panel's TOP edge stays pinned
    /// just below the status item button; only the height (growing downward) and,
    /// via live frame recomputation, width ever change -- the anchor point itself
    /// never moves regardless of how tall the content gets.
    private func reposition() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonFrameOnScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))

        let fitting = hostingController.view.fittingSize
        let width = max(fitting.width, 1)
        let height = max(fitting.height, 1)

        let gap: CGFloat = 6
        let topY = buttonFrameOnScreen.minY - gap
        var originX = buttonFrameOnScreen.midX - width / 2
        if let screenFrame = buttonWindow.screen?.visibleFrame {
            originX = min(max(originX, screenFrame.minX + 8), screenFrame.maxX - width - 8)
        }

        panel.setFrame(NSRect(x: originX, y: topY - height, width: width, height: height), display: true)
    }

    private func startOutsideDismissMonitors() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.close() } // Escape
            return event
        }
    }

    private func close() {
        panel.orderOut(nil)
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let keyDownMonitor { NSEvent.removeMonitor(keyDownMonitor) }
        outsideClickMonitor = nil
        keyDownMonitor = nil
    }

    private func quit() {
        model.shutdown()
        NSApp.terminate(nil)
    }
}
