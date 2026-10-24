import AppKit
import Combine
import CoreAudio

struct AppRow: Identifiable, Equatable {
    let id: pid_t
    let bundleID: String
    let name: String
    let icon: NSImage
    var volume: Float
    var isMuted: Bool
    var outputDeviceUID: String?

    static func == (lhs: AppRow, rhs: AppRow) -> Bool {
        lhs.id == rhs.id && lhs.volume == rhs.volume && lhs.isMuted == rhs.isMuted
            && lhs.outputDeviceUID == rhs.outputDeviceUID
    }
}

/// Keeps one `ProcessAudioRoute` running per app that's currently playing audio, so
/// each row's slider is live the moment the app shows up -- matching SoundSource's
/// always-on per-app volume knob rather than a manual "enable routing" step.
///
/// System alert/notification sounds (`systemsoundserverd`) are tracked the same way
/// under the hood but kept out of `apps` and exposed separately as `systemSoundsRow`,
/// pinned and always present -- the underlying process only spins up output for the
/// instant it plays a sound, so treating it as a normal app row made it flicker in and
/// out of the list.
@available(macOS 14.2, *)
final class AudioMixerModel: ObservableObject {
    @Published private(set) var apps: [AppRow] = []
    @Published private(set) var systemSoundsRow: AppRow?
    @Published private(set) var devices: [AudioDevice] = []

    private var activeRoutes: [pid_t: ProcessAudioRoute] = [:]
    private var volumes: [pid_t: Float] = [:]
    private var muted: Set<pid_t> = []
    private var outputDeviceUIDs: [pid_t: String] = [:]
    private var missingStreak: [pid_t: Int] = [:]
    private var systemSoundsPID: pid_t?
    private var refreshTimer: Timer?
    private static let genericAppIcon = NSWorkspace.shared.icon(for: .application)
    private static let systemSoundsIcon = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: "System Sounds")
        ?? genericAppIcon

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
        devices = AudioDeviceManager.outputDevices()
        refreshSystemSounds()

        let processes = AudioProcessManager.runningAudioProcesses()
        let currentPIDs = Set(processes.map(\.pid))

        for process in processes {
            missingStreak[process.pid] = 0
            guard activeRoutes[process.pid] == nil else { continue }
            startRoute(for: process)
        }

        for pid in activeRoutes.keys where !currentPIDs.contains(pid) && pid != systemSoundsPID {
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
        let stillGraced = Set(activeRoutes.keys).subtracting(currentPIDs).subtracting([systemSoundsPID].compactMap { $0 })
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
                volume: volumes[pid] ?? 1.0,
                isMuted: muted.contains(pid),
                outputDeviceUID: outputDeviceUIDs[pid] ?? AudioDeviceManager.defaultOutputDeviceUID()
            )
        }.sorted { $0.name < $1.name }
    }

    private func refreshSystemSounds() {
        guard let process = AudioProcessManager.systemSoundsProcess() else {
            systemSoundsRow = nil
            return
        }

        if systemSoundsPID != process.pid {
            // Daemon restarted under a new pid (rare) -- drop the stale route.
            if let oldPID = systemSoundsPID {
                activeRoutes[oldPID]?.stop()
                activeRoutes[oldPID] = nil
            }
            systemSoundsPID = process.pid
        }

        if activeRoutes[process.pid] == nil {
            startRoute(for: process)
        }

        systemSoundsRow = AppRow(
            id: process.pid,
            bundleID: process.bundleID,
            name: "System Sounds",
            icon: Self.systemSoundsIcon,
            volume: volumes[process.pid] ?? 1.0,
            isMuted: muted.contains(process.pid),
            outputDeviceUID: outputDeviceUIDs[process.pid] ?? AudioDeviceManager.defaultOutputDeviceUID()
        )
    }

    private func startRoute(for process: AudioProcess) {
        let route = ProcessAudioRoute(process: process)
        do {
            try route.start(outputDeviceUID: outputDeviceUIDs[process.pid])
            route.volume = appliedVolume(for: process.pid)
            activeRoutes[process.pid] = route
        } catch {
            NSLog("VolumeControl: failed to start capture for \(process.bundleID): \(error)")
        }
    }

    private func appliedVolume(for pid: pid_t) -> Float {
        muted.contains(pid) ? 0 : (volumes[pid] ?? 1.0)
    }

    private func updateRow(id: pid_t, _ transform: (inout AppRow) -> Void) {
        if systemSoundsRow?.id == id {
            var row = systemSoundsRow!
            transform(&row)
            systemSoundsRow = row
        } else if let index = apps.firstIndex(where: { $0.id == id }) {
            transform(&apps[index])
        }
    }

    func setVolume(_ volume: Float, for row: AppRow) {
        volumes[row.id] = volume
        activeRoutes[row.id]?.volume = appliedVolume(for: row.id)
        updateRow(id: row.id) { $0.volume = volume }
    }

    func toggleMute(for row: AppRow) {
        if muted.contains(row.id) {
            muted.remove(row.id)
        } else {
            muted.insert(row.id)
        }
        activeRoutes[row.id]?.volume = appliedVolume(for: row.id)
        updateRow(id: row.id) { $0.isMuted = self.muted.contains(row.id) }
    }

    func setOutputDevice(_ device: AudioDevice, for row: AppRow) {
        outputDeviceUIDs[row.id] = device.uid
        updateRow(id: row.id) { $0.outputDeviceUID = device.uid }
        guard let route = activeRoutes[row.id] else { return }
        do {
            try route.setOutputDevice(uid: device.uid)
        } catch {
            NSLog("VolumeControl: failed to switch output device for pid \(row.id): \(error)")
        }
    }

    func shutdown() {
        for route in activeRoutes.values { route.stop() }
        activeRoutes.removeAll()
    }
}
