import AppKit
import Combine
import CoreAudio

struct AppRow: Identifiable, Equatable {
    let id: pid_t
    let bundleID: String
    let name: String
    /// Real app icon, used for normal per-app rows.
    let icon: NSImage?
    /// SF Symbol name, used instead of `icon` for pinned system rows (e.g. "System
    /// Sounds") so they render smaller and in the same secondary gray as other pinned
    /// controls rather than looking like a full-size, full-color app icon.
    let leadingSystemSymbolName: String?
    var volume: Float
    var isMuted: Bool
    var outputDeviceUID: String?

    static func == (lhs: AppRow, rhs: AppRow) -> Bool {
        lhs.id == rhs.id && lhs.volume == rhs.volume && lhs.isMuted == rhs.isMuted
            && lhs.outputDeviceUID == rhs.outputDeviceUID
    }
}

/// One row in the "Device Levels" section -- a connected output device's own stored
/// CoreAudio volume/mute, independent of (and the actual root cause behind) any
/// per-app volume: macOS remembers this separately per device, so a Bluetooth headset
/// and the built-in speakers can genuinely be set to very different stored levels.
struct DeviceLevelRow: Identifiable, Equatable {
    let id: AudioObjectID
    let name: String
    let iconSymbolName: String
    var volume: Float
    var isMuted: Bool
}

enum DeviceRoutingMode: String {
    case single = "Single"
    case multiple = "Multiple"
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
    @Published private(set) var masterVolume: Float = 1.0
    @Published private(set) var isMasterMuted: Bool = false
    @Published private(set) var deviceLevels: [DeviceLevelRow] = []
    /// pids currently mid-device-switch: muted and showing a loading indicator instead
    /// of the device icon (see setOutputDevice(_:for:)).
    @Published private(set) var pendingDeviceSwitchPIDs: Set<pid_t> = []

    private var activeRoutes: [pid_t: ProcessAudioRoute] = [:]
    private var volumes: [pid_t: Float] = [:]
    private var muted: Set<pid_t> = []
    private var outputDeviceUIDs: [pid_t: String] = [:]
    private var missingStreak: [pid_t: Int] = [:]
    private var systemSoundsPID: pid_t?
    /// `systemsoundserverd` itself drops out of
    /// kAudioHardwarePropertyProcessObjectList entirely after a while with no sound
    /// played -- not just its isRunningOutput flag going false, the whole process
    /// object becomes briefly unqueryable. Caching the last-found identity and only
    /// ever updating it (never clearing it) keeps the pinned row and its already-
    /// running route alive through that, instead of the row vanishing whenever no
    /// alert sound has played recently.
    private var lastKnownSystemSoundsProcess: AudioProcess?
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
        devices = AudioDeviceManager.outputDevices()
        // Ground truth for master volume/mute lives in the OS (volume keys, Control
        // Center can change it outside this app), so read it fresh each time rather
        // than tracking our own copy -- unlike per-app volume, which only we control.
        if let liveVolume = AudioDeviceManager.masterVolume() {
            masterVolume = liveVolume
        }
        isMasterMuted = AudioDeviceManager.isMasterMuted()
        // Same read-through approach, per device: this is macOS's own stored level for
        // each device, which other apps/the volume keys can also change.
        deviceLevels = devices.compactMap { device in
            guard let volume = AudioDeviceManager.volume(for: device.id) else { return nil }
            return DeviceLevelRow(id: device.id, name: device.name, iconSymbolName: device.iconSymbolName,
                                   volume: volume, isMuted: AudioDeviceManager.isMuted(device.id))
        }
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
                leadingSystemSymbolName: nil,
                volume: volumes[pid] ?? 1.0,
                isMuted: muted.contains(pid),
                outputDeviceUID: outputDeviceUIDs[pid] ?? AudioDeviceManager.defaultOutputDeviceUID()
            )
        }.sorted { $0.name < $1.name }
    }

    private func refreshSystemSounds() {
        if let liveProcess = AudioProcessManager.systemSoundsProcess() {
            lastKnownSystemSoundsProcess = liveProcess
        }
        guard let process = lastKnownSystemSoundsProcess else {
            systemSoundsRow = nil // only possible before it's ever been found once
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
            icon: nil,
            leadingSystemSymbolName: "bell.fill",
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

    /// Switching the output device the first time can report success before the device
    /// -- especially Bluetooth -- is actually flowing audio yet (observed directly:
    /// the first bind sometimes doesn't produce sound, but a prompt second bind always
    /// does). Rather than make the user manually retry, this mutes the app, rebinds,
    /// waits for the device to settle, rebinds again to reliably catch it up, then
    /// unmutes -- with pendingDeviceSwitchPIDs driving a loading indicator in place of
    /// the device icon for that window so it's visibly "in progress," not silently
    /// broken.
    func setOutputDevice(_ device: AudioDevice, for row: AppRow) {
        outputDeviceUIDs[row.id] = device.uid
        updateRow(id: row.id) { $0.outputDeviceUID = device.uid }
        guard let route = activeRoutes[row.id] else { return }

        let pid = row.id
        let restoreVolume = appliedVolume(for: pid)
        pendingDeviceSwitchPIDs.insert(pid)
        route.volume = 0

        do {
            try route.setOutputDevice(uid: device.uid)
        } catch {
            NSLog("VolumeControl: failed to switch output device for pid \(pid): \(error)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            if let route = self.activeRoutes[pid] {
                do {
                    try route.setOutputDevice(uid: device.uid)
                } catch {
                    NSLog("VolumeControl: failed to re-confirm output device for pid \(pid): \(error)")
                }
                route.volume = restoreVolume
            }
            self.pendingDeviceSwitchPIDs.remove(pid)
        }
    }

    func setMasterVolume(_ volume: Float) {
        masterVolume = volume
        AudioDeviceManager.setMasterVolume(volume)
    }

    func toggleMasterMute() {
        isMasterMuted.toggle()
        AudioDeviceManager.setMasterMuted(isMasterMuted)
    }

    /// Purely derived from the actual current per-row output device selections -- not
    /// separately stored state. "Single" whenever every row with a destination (System
    /// Sounds + every app) points at the same device; "Multiple" the moment any of them
    /// diverges, including via a manual per-app device pick while in Single mode.
    var deviceMode: DeviceRoutingMode {
        var uids = Set<String>()
        if let uid = systemSoundsRow?.outputDeviceUID { uids.insert(uid) }
        for app in apps {
            if let uid = app.outputDeviceUID { uids.insert(uid) }
        }
        return uids.count <= 1 ? .single : .multiple
    }

    /// Consolidates System Sounds and every app onto one device: a headphone/earbud-type
    /// device if one's connected (treated as first priority, per request), else the
    /// built-in speakers, else whatever the system default currently is.
    func consolidateToSingleDevice() {
        guard let target = preferredSingleDevice() else { return }
        if let systemRow = systemSoundsRow {
            setOutputDevice(target, for: systemRow)
        }
        for app in apps {
            setOutputDevice(target, for: app)
        }
    }

    private func preferredSingleDevice() -> AudioDevice? {
        let headphoneLikeIcons: Set<String> = ["headphones", "earbuds", "airpods", "airpodsmax", "beats.headphones"]
        if let headphones = devices.first(where: { headphoneLikeIcons.contains($0.iconSymbolName) }) {
            return headphones
        }
        if let builtIn = devices.first(where: { $0.transportType == kAudioDeviceTransportTypeBuiltIn }) {
            return builtIn
        }
        if let defaultUID = AudioDeviceManager.defaultOutputDeviceUID(), let match = devices.first(where: { $0.uid == defaultUID }) {
            return match
        }
        return devices.first
    }

    func setDeviceVolume(_ volume: Float, for row: DeviceLevelRow) {
        AudioDeviceManager.setVolume(volume, for: row.id)
        if let index = deviceLevels.firstIndex(where: { $0.id == row.id }) {
            deviceLevels[index].volume = volume
        }
    }

    func toggleDeviceMute(for row: DeviceLevelRow) {
        let newMuted = !row.isMuted
        AudioDeviceManager.setMuted(newMuted, for: row.id)
        if let index = deviceLevels.firstIndex(where: { $0.id == row.id }) {
            deviceLevels[index].isMuted = newMuted
        }
    }

    func shutdown() {
        for route in activeRoutes.values { route.stop() }
        activeRoutes.removeAll()
    }
}
