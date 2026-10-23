import AppKit
import Combine
import CoreAudio

struct AppRow: Identifiable, Equatable {
    let id: pid_t
    let audioObjectID: AudioObjectID
    let bundleID: String
    let name: String
    let icon: NSImage
    var isRouted: Bool
    var volume: Float
    var outputDeviceUID: String?

    static func == (lhs: AppRow, rhs: AppRow) -> Bool {
        lhs.id == rhs.id && lhs.isRouted == rhs.isRouted && lhs.volume == rhs.volume
            && lhs.outputDeviceUID == rhs.outputDeviceUID
    }
}

@available(macOS 14.2, *)
final class AudioMixerModel: ObservableObject {
    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var defaultDeviceUID: String?
    @Published private(set) var apps: [AppRow] = []

    private var activeRoutes: [pid_t: ProcessAudioRoute] = [:]
    private var perAppOutputUID: [pid_t: String] = [:]
    private var perAppVolume: [pid_t: Float] = [:]
    private var refreshTimer: Timer?
    private static let genericAppIcon = NSWorkspace.shared.icon(for: .application)

    init() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        devices = (try? AudioDeviceManager.outputDevices()) ?? []
        defaultDeviceUID = AudioDeviceManager.defaultOutputDevice().flatMap(AudioDeviceManager.deviceUID(for:))

        apps = AudioProcessManager.runningAudioProcesses().map { process in
            let running = NSRunningApplication(processIdentifier: process.pid)
            let name = running?.localizedName ?? process.bundleID
            let icon = running?.icon ?? Self.genericAppIcon
            return AppRow(
                id: process.pid,
                audioObjectID: process.id,
                bundleID: process.bundleID,
                name: name,
                icon: icon,
                isRouted: activeRoutes[process.pid] != nil,
                volume: perAppVolume[process.pid] ?? 1.0,
                outputDeviceUID: perAppOutputUID[process.pid] ?? defaultDeviceUID
            )
        }
    }

    func selectDefaultDevice(_ device: AudioDevice) {
        try? AudioDeviceManager.setDefaultOutputDevice(device.id)
        refresh()
    }

    func toggleRouting(for row: AppRow) {
        if let route = activeRoutes[row.id] {
            route.stop()
            activeRoutes[row.id] = nil
        } else {
            let targetUID = perAppOutputUID[row.id] ?? defaultDeviceUID ?? devices.first?.uid
            guard let targetUID else { return }
            let process = AudioProcess(id: row.audioObjectID, pid: row.id, bundleID: row.bundleID)
            let route = ProcessAudioRoute(process: process)
            do {
                try route.start(outputDeviceUID: targetUID)
                route.volume = perAppVolume[row.id] ?? 1.0
                activeRoutes[row.id] = route
                perAppOutputUID[row.id] = targetUID
            } catch {
                NSLog("VolumeControl: failed to start routing for \(row.bundleID): \(error)")
            }
        }
        refresh()
    }

    func setVolume(_ volume: Float, for row: AppRow) {
        perAppVolume[row.id] = volume
        activeRoutes[row.id]?.volume = volume
        if let index = apps.firstIndex(where: { $0.id == row.id }) {
            apps[index].volume = volume
        }
    }

    func setOutputDevice(_ device: AudioDevice, for row: AppRow) {
        perAppOutputUID[row.id] = device.uid
        if let route = activeRoutes[row.id] {
            try? route.updateOutputDevice(outputDeviceUID: device.uid)
        }
        refresh()
    }

    func shutdown() {
        for route in activeRoutes.values { route.stop() }
        activeRoutes.removeAll()
    }
}
