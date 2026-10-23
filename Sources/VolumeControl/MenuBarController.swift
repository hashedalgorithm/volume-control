import AppKit

/// A menu item row with a volume slider, used for both the per-app rows and could be
/// reused for a master volume row later.
final class SliderMenuItemView: NSView {
    let slider = NSSlider(value: 1.0, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
    private let label = NSTextField(labelWithString: "")

    init(title: String, value: Float, width: CGFloat = 220) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 34))
        label.frame = NSRect(x: 14, y: 16, width: width - 28, height: 16)
        label.font = .systemFont(ofSize: 12)
        label.stringValue = title
        addSubview(label)

        slider.frame = NSRect(x: 14, y: 2, width: width - 28, height: 16)
        slider.floatValue = value
        addSubview(slider)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }
}

@available(macOS 14.2, *)
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var activeRoutes: [pid_t: ProcessAudioRoute] = [:]
    private var perAppOutputUID: [pid_t: String] = [:]
    private var refreshTimer: Timer?

    override init() {
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Volume Control")
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.rebuildMenu()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        menu.addItem(withTitle: "Output Device", action: nil, keyEquivalent: "").isEnabled = false
        let devices = (try? AudioDeviceManager.outputDevices()) ?? []
        let currentDefault = AudioDeviceManager.defaultOutputDevice().flatMap(AudioDeviceManager.deviceUID(for:))
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectDefaultDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device
            item.state = device.uid == currentDefault ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "App Volume & Routing", action: nil, keyEquivalent: "").isEnabled = false

        let processes = AudioProcessManager.runningAudioProcesses()
        if processes.isEmpty {
            menu.addItem(withTitle: "No apps currently playing audio", action: nil, keyEquivalent: "").isEnabled = false
        }
        for process in processes {
            addAppItem(for: process, devices: devices)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Volume Control", action: #selector(quit), keyEquivalent: "q").target = self
    }

    private func addAppItem(for process: AudioProcess, devices: [AudioDevice]) {
        let appItem = NSMenuItem(title: process.displayName, action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let isRouted = activeRoutes[process.pid] != nil
        let toggleItem = NSMenuItem(
            title: isRouted ? "Routing Enabled" : "Route This App's Audio",
            action: #selector(toggleRouting(_:)),
            keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.representedObject = process
        toggleItem.state = isRouted ? .on : .off
        submenu.addItem(toggleItem)

        if isRouted {
            let sliderView = SliderMenuItemView(title: "Volume", value: activeRoutes[process.pid]?.volume ?? 1.0)
            sliderView.slider.target = self
            sliderView.slider.action = #selector(volumeChanged(_:))
            sliderView.slider.tag = Int(process.pid)
            let sliderItem = NSMenuItem()
            sliderItem.view = sliderView
            submenu.addItem(sliderItem)

            submenu.addItem(.separator())
            submenu.addItem(withTitle: "Send To:", action: nil, keyEquivalent: "").isEnabled = false
            let selectedUID = perAppOutputUID[process.pid]
            for device in devices {
                let deviceItem = NSMenuItem(title: device.name, action: #selector(selectAppDevice(_:)), keyEquivalent: "")
                deviceItem.target = self
                deviceItem.representedObject = (process, device)
                deviceItem.state = device.uid == selectedUID ? .on : .off
                submenu.addItem(deviceItem)
            }
        }

        appItem.submenu = submenu
        menu.addItem(appItem)
    }

    @objc private func selectDefaultDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? AudioDevice else { return }
        try? AudioDeviceManager.setDefaultOutputDevice(device.id)
        rebuildMenu()
    }

    @objc private func toggleRouting(_ sender: NSMenuItem) {
        guard let process = sender.representedObject as? AudioProcess else { return }
        if let route = activeRoutes[process.pid] {
            route.stop()
            activeRoutes[process.pid] = nil
        } else {
            let devices = (try? AudioDeviceManager.outputDevices()) ?? []
            let targetUID = perAppOutputUID[process.pid]
                ?? AudioDeviceManager.defaultOutputDevice().flatMap(AudioDeviceManager.deviceUID(for:))
                ?? devices.first?.uid
            guard let targetUID else { return }
            let route = ProcessAudioRoute(process: process)
            do {
                try route.start(outputDeviceUID: targetUID)
                activeRoutes[process.pid] = route
                perAppOutputUID[process.pid] = targetUID
            } catch {
                NSLog("VolumeControl: failed to start routing for \(process.bundleID): \(error)")
            }
        }
        rebuildMenu()
    }

    @objc private func selectAppDevice(_ sender: NSMenuItem) {
        guard let (process, device) = sender.representedObject as? (AudioProcess, AudioDevice) else { return }
        perAppOutputUID[process.pid] = device.uid
        if let route = activeRoutes[process.pid] {
            try? route.updateOutputDevice(outputDeviceUID: device.uid)
        }
        rebuildMenu()
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        let pid = pid_t(sender.tag)
        activeRoutes[pid]?.volume = sender.floatValue
    }

    @objc private func quit() {
        for route in activeRoutes.values { route.stop() }
        NSApp.terminate(nil)
    }
}
