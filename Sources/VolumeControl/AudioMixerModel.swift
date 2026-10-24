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
    private var missingStreak: [pid_t: Int] = [:]
    private var refreshTimer: Timer?
    private static let genericAppIcon = NSWorkspace.shared.icon(for: .application)

    /// `kAudioProcessPropertyIsRunningOutput` flickers false for a single poll between
    /// tracks, during buffering, etc. Tearing down the tap+aggregate+engine on every
    /// such blip is what caused the dropouts/silence -- only treat an app as gone after
    /// it's been absent this many consecutive polls.
    private static let missingPollsBeforeStop = 3

    init() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let processes = AudioProcessManager.runningAudioProcesses()
        let currentPIDs = Set(processes.map(\.pid))

        for process in processes {
            missingStreak[process.pid] = 0
            guard activeRoutes[process.pid] == nil else { continue }
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
            let streak = (missingStreak[pid] ?? 0) + 1
            missingStreak[pid] = streak
            if streak >= Self.missingPollsBeforeStop {
                activeRoutes[pid]?.stop()
                activeRoutes[pid] = nil
                missingStreak[pid] = nil
            }
        }

        // Keep showing rows for apps still within their grace period so the slider
        // doesn't flicker out and back during a momentary isRunningOutput blip.
        let stillGraced = Set(activeRoutes.keys).subtracting(currentPIDs)
        let displayedPIDs = currentPIDs.union(stillGraced)

        apps = displayedPIDs.compactMap { pid -> AppRow? in
            let process = processes.first(where: { $0.pid == pid })
            let running = NSRunningApplication(processIdentifier: pid)
            guard let bundleID = process?.bundleID ?? running?.bundleIdentifier else { return nil }
            return AppRow(
                id: pid,
                bundleID: bundleID,
                name: running?.localizedName ?? bundleID,
                icon: running?.icon ?? Self.genericAppIcon,
                volume: volumes[pid] ?? 1.0
            )
        }.sorted { $0.name < $1.name }
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
