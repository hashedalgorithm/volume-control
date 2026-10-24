import AppKit
import Combine
import CoreAudio

struct AppRow: Identifiable, Equatable {
    let id: pid_t
    let bundleID: String
    let name: String
    let icon: NSImage
    var volume: Float

    static func == (lhs: AppRow, rhs: AppRow) -> Bool {
        lhs.id == rhs.id && lhs.volume == rhs.volume
    }
}

/// Keeps one `ProcessAudioRoute` running per app that's currently playing audio, so
/// each row's slider is live the moment the app shows up -- matching SoundSource's
/// always-on per-app volume knob rather than a manual "enable routing" step.
@available(macOS 14.2, *)
final class AudioMixerModel: ObservableObject {
    @Published private(set) var apps: [AppRow] = []

    private var activeRoutes: [pid_t: ProcessAudioRoute] = [:]
    private var volumes: [pid_t: Float] = [:]
    private var refreshTimer: Timer?
    private static let genericAppIcon = NSWorkspace.shared.icon(for: .application)

    init() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let processes = AudioProcessManager.runningAudioProcesses()
        let currentPIDs = Set(processes.map(\.pid))

        for process in processes where activeRoutes[process.pid] == nil {
            let route = ProcessAudioRoute(process: process)
            do {
                try route.start()
                route.volume = volumes[process.pid] ?? 1.0
                activeRoutes[process.pid] = route
            } catch {
                NSLog("VolumeControl: failed to start capture for \(process.bundleID): \(error)")
            }
        }

        for pid in activeRoutes.keys where !currentPIDs.contains(pid) {
            activeRoutes[pid]?.stop()
            activeRoutes[pid] = nil
        }

        apps = processes.map { process in
            let running = NSRunningApplication(processIdentifier: process.pid)
            return AppRow(
                id: process.pid,
                bundleID: process.bundleID,
                name: running?.localizedName ?? process.bundleID,
                icon: running?.icon ?? Self.genericAppIcon,
                volume: volumes[process.pid] ?? 1.0
            )
        }
    }

    func setVolume(_ volume: Float, for row: AppRow) {
        volumes[row.id] = volume
        activeRoutes[row.id]?.volume = volume
        if let index = apps.firstIndex(where: { $0.id == row.id }) {
            apps[index].volume = volume
        }
    }

    func shutdown() {
        for route in activeRoutes.values { route.stop() }
        activeRoutes.removeAll()
    }
}
