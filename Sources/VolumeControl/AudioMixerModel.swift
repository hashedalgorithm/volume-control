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
    var boost: AppBoostPreference

    static func == (lhs: AppRow, rhs: AppRow) -> Bool {
        lhs.id == rhs.id && lhs.volume == rhs.volume && lhs.isMuted == rhs.isMuted
            && lhs.outputDeviceUID == rhs.outputDeviceUID && lhs.boost == rhs.boost
    }
}

/// One row in the "Device Levels" section -- a connected output device's own stored
/// CoreAudio volume/mute, independent of (and the actual root cause behind) any
/// per-app volume: macOS remembers this separately per device, so a Bluetooth headset
/// and the built-in speakers can genuinely be set to very different stored levels.
///
/// Doubles as a *group* volume for every app explicitly routed to this device (a
/// per-app pick, or priority routing) -- see AudioMixerModel.applyDeviceGroupMultipliers
/// for why: an explicit device binding doesn't reliably get its volume from that
/// device's own native CoreAudio property at all (confirmed directly with an app
/// pinned to a connected HDMI output -- including once priority routing had also made
/// that same HDMI device the system default, ruling out "it's just not the default" as
/// the reason), which is exactly what made adjusting this slider a no-op for apps
/// routed there. `uid` is what keys that group-volume bookkeeping and is also what some
/// devices' *native* volume read fails for entirely (e.g. that same HDMI device) --
/// this row still exists for those, just driven purely by the software multiplier.
struct DeviceLevelRow: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let iconSymbolName: String
    var volume: Float
    var isMuted: Bool
}

enum DeviceRoutingMode: String {
    case single = "Single"
    case multiple = "Multiple"
}

/// One entry in the user-ordered output-priority list (Preferences > Output Priority).
/// Stores `name` alongside `uid` so a device that's since been unplugged still shows a
/// readable label in the list instead of a bare UID -- CoreAudio can't tell us a
/// disconnected device's name since it's no longer enumerable.
struct OutputPriorityEntry: Codable, Equatable, Identifiable {
    let uid: String
    let name: String
    var id: String { uid }
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
    @Published private(set) var deviceLevels: [DeviceLevelRow] = []
    /// pids currently mid-device-switch: muted and showing a loading indicator instead
    /// of the device icon (see setOutputDevice(_:for:)).
    @Published private(set) var pendingDeviceSwitchPIDs: Set<pid_t> = []
    /// App-wide extra multiplier, adjustable in Preferences -- applied identically
    /// to every route's final gain on top of its own volume/boost (see
    /// ProcessAudioRoute.globalMultiplier). 1.0 is a no-op; range enforced in
    /// setGlobalBoostMultiplier.
    @Published private(set) var globalBoostMultiplier: Float = 1.0
    /// Whether output-priority auto-routing (Preferences > Output Priority) is active
    /// at all -- off by default so existing installs keep today's plain "system
    /// default, or whatever's explicitly picked per app" behavior unless opted in.
    @Published private(set) var outputPriorityEnabled: Bool = false
    /// User-ordered most- to least-preferred devices; the first one currently connected
    /// wins. An explicit per-app output pick (setOutputDevice) still beats this as long
    /// as that pinned device is itself connected -- this only decides the *fallback*
    /// every app without its own pin (and the system default itself) follows.
    @Published private(set) var outputPriorityOrder: [OutputPriorityEntry] = []

    private var activeRoutes: [pid_t: ProcessAudioRoute] = [:]
    private var volumes: [pid_t: Float] = [:]
    private var muted: Set<pid_t> = []
    private var outputDeviceUIDs: [pid_t: String] = [:]
    private var missingStreak: [pid_t: Int] = [:]
    /// pid-keyed dicts above are the live, in-session cache -- pids are a new random
    /// number every process launch, useless as a persistence key. This is the actual
    /// persisted store, keyed by bundle ID, written through on every change and read
    /// to seed a process's live state the first time it's seen each session (see
    /// seedLiveStateIfNeeded(for:)), which is what makes a setting survive the app
    /// restarting, the target app restarting, or a full system reboot.
    private let persistedOutputPrefs = PersistedStore<AppOutputPreference>(
        defaultsKey: "outputAppPreferences", defaultValue: AppOutputPreference()
    )
    private var boosts: [pid_t: AppBoostPreference] = [:]
    private let persistedBoostPrefs = PersistedStore<AppBoostPreference>(
        defaultsKey: "outputAppBoostPreferences", defaultValue: AppBoostPreference()
    )
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

    /// The priority-list device currently resolved as "in effect," or nil if priority
    /// routing is off or none of the listed devices are connected right now. Compared
    /// against on every refresh so the system default is only re-set (and routes only
    /// re-pointed) on an actual change, not redundantly every 2 seconds.
    private var lastResolvedPriorityUID: String?
    /// What output device each active route was last told to use, keyed by pid --
    /// `systemDefaultSentinel` stands in for "no explicit target, follow the system
    /// default" since a plain `[pid_t: String?]` can't be compared for equality against
    /// a fresh `String?` without double-optional headaches. Cleared whenever a route
    /// stops, alongside activeRoutes/missingStreak.
    private var appliedOutputUID: [pid_t: String] = [:]
    private static let systemDefaultSentinel = ""

    /// Device Levels' per-device "group volume"/mute, keyed by device UID -- driven by
    /// the same slider/mute button as that device's own native CoreAudio volume
    /// (setDeviceVolume/toggleDeviceMute), but applied as a software gain multiplier to
    /// every active route that's *explicitly* bound to that device (see
    /// applyDeviceGroupMultipliers for why "explicitly bound," not "non-default," is the
    /// deciding factor). Persisted so a device's group level survives restarts the same
    /// way its native volume already does.
    private var deviceGroupVolumes: [String: Float] = [:]
    private var deviceGroupMuted: Set<String> = []
    private static let deviceGroupVolumesDefaultsKey = "deviceGroupVolumes"
    private static let deviceGroupMutedDefaultsKey = "deviceGroupMuted"
    /// Last multiplier actually pushed to each route, to skip a redundant
    /// engine-gain update when nothing changed -- same caching approach as
    /// appliedOutputUID.
    private var appliedDeviceGroupMultiplier: [pid_t: Float] = [:]

    /// Per-pid cooldown after a route repeatedly fails to start, so a device that's
    /// stuck (wedged hardware, not-yet-reconnected Bluetooth, etc.) doesn't get hammered
    /// with a fresh tap+aggregate+engine attempt every single 2-second refresh forever.
    /// Confirmed directly: a wedged HDMI audio endpoint took ~11s to fail `kAUStartIO`,
    /// twice in a row, and without this, that same ~22s failure would've repeated every
    /// 2 seconds for as long as the device stayed wedged -- the likely actual mechanism
    /// behind "the popup hangs after an abrupt shutdown until I reboot the whole Mac":
    /// persisted per-app device picks getting retried against hardware that hasn't
    /// settled yet right after an unclean restart, over and over, with no backoff.
    ///
    /// This doesn't stop a single attempt from blocking the main thread for however
    /// long CoreAudio takes to fail (that would need routing ProcessAudioRoute's calls
    /// through a queue it owns internally, with its own synchronization for the
    /// AVAudioEngine/CoreAudio state those calls touch -- a larger, riskier change than
    /// is safe to make without dedicated testing, so it's intentionally not part of this
    /// fix). What this does fix is the UI being hung *repeatedly, indefinitely* rather
    /// than just once per device per cooldown window.
    private var routeStartBackoffUntil: [pid_t: Date] = [:]
    private static let routeStartBackoffInterval: TimeInterval = 15

    /// `kAudioProcessPropertyIsRunningOutput` flickers false for a single poll between
    /// tracks, during buffering, etc. Tearing down the tap+aggregate+engine on every
    /// such blip is what caused the dropouts/silence -- only treat an app as gone after
    /// it's been absent this many consecutive polls.
    private static let missingPollsBeforeStop = 3
    private static let globalBoostMultiplierDefaultsKey = "globalBoostMultiplier"
    static let globalBoostMultiplierRange: ClosedRange<Float> = 0...3
    private static let outputPriorityEnabledDefaultsKey = "outputPriorityEnabled"
    private static let outputPriorityOrderDefaultsKey = "outputPriorityOrder"

    init() {
        if UserDefaults.standard.object(forKey: Self.globalBoostMultiplierDefaultsKey) != nil {
            globalBoostMultiplier = UserDefaults.standard.float(forKey: Self.globalBoostMultiplierDefaultsKey)
        }
        outputPriorityEnabled = UserDefaults.standard.bool(forKey: Self.outputPriorityEnabledDefaultsKey)
        if let data = UserDefaults.standard.data(forKey: Self.outputPriorityOrderDefaultsKey),
           let decoded = try? JSONDecoder().decode([OutputPriorityEntry].self, from: data) {
            outputPriorityOrder = decoded
        }
        if let data = UserDefaults.standard.data(forKey: Self.deviceGroupVolumesDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: Float].self, from: data) {
            deviceGroupVolumes = decoded
        }
        deviceGroupMuted = Set(UserDefaults.standard.stringArray(forKey: Self.deviceGroupMutedDefaultsKey) ?? [])
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Clamped to globalBoostMultiplierRange, persisted, and pushed to every
    /// currently-running route immediately -- unlike per-app boost (which only
    /// takes effect for that one app), this is meant to feel live for whatever's
    /// already playing, not just apps started after the change.
    func setGlobalBoostMultiplier(_ value: Float) {
        let clamped = min(Self.globalBoostMultiplierRange.upperBound, max(Self.globalBoostMultiplierRange.lowerBound, value))
        globalBoostMultiplier = clamped
        UserDefaults.standard.set(clamped, forKey: Self.globalBoostMultiplierDefaultsKey)
        for route in activeRoutes.values { route.globalMultiplier = clamped }
    }

    func setOutputPriorityEnabled(_ enabled: Bool) {
        outputPriorityEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.outputPriorityEnabledDefaultsKey)
        resolveOutputPriorityTarget()
        applyOutputRoutingToActiveRoutes()
    }

    func addToOutputPriority(_ device: AudioDevice) {
        guard !outputPriorityOrder.contains(where: { $0.uid == device.uid }) else { return }
        outputPriorityOrder.append(OutputPriorityEntry(uid: device.uid, name: device.name))
        persistOutputPriorityOrder()
        resolveOutputPriorityTarget()
        applyOutputRoutingToActiveRoutes()
    }

    func removeFromOutputPriority(_ entry: OutputPriorityEntry) {
        outputPriorityOrder.removeAll { $0.uid == entry.uid }
        persistOutputPriorityOrder()
        resolveOutputPriorityTarget()
        applyOutputRoutingToActiveRoutes()
    }

    func moveOutputPriority(fromOffsets: IndexSet, toOffset: Int) {
        outputPriorityOrder.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persistOutputPriorityOrder()
        resolveOutputPriorityTarget()
        applyOutputRoutingToActiveRoutes()
    }

    private func persistOutputPriorityOrder() {
        guard let data = try? JSONEncoder().encode(outputPriorityOrder) else { return }
        UserDefaults.standard.set(data, forKey: Self.outputPriorityOrderDefaultsKey)
    }

    /// Recomputes which priority-list device is currently connected and in effect, and
    /// -- only on an actual change -- pushes it as the system's own default output
    /// device too, so untapped audio (and anything that isn't a per-app route at all)
    /// follows the same preference, not just this app's own routed apps.
    private func resolveOutputPriorityTarget() {
        guard outputPriorityEnabled else {
            lastResolvedPriorityUID = nil
            return
        }
        let connectedUIDs = Set(devices.map(\.uid))
        let resolved = outputPriorityOrder.first(where: { connectedUIDs.contains($0.uid) })?.uid
        guard resolved != lastResolvedPriorityUID else { return }
        lastResolvedPriorityUID = resolved
        guard let resolved, AudioDeviceManager.defaultOutputDeviceUID() != resolved,
              let deviceID = AudioDeviceManager.deviceID(forUID: resolved) else { return }
        AudioDeviceManager.setDefaultOutputDevice(deviceID)
        ErrorLogger.shared.info("output priority: switched system default output device to \(resolved)")
    }

    /// Per active route (including System Sounds, since it's in activeRoutes too),
    /// figures out which device should actually be in effect -- an explicit per-app
    /// pick, as long as it's still connected, otherwise the priority-resolved device --
    /// and only touches the route (tears down/rebuilds its playback engine) when that
    /// target actually changed since the last time this ran. Covers both directions:
    /// a priority device appearing/disappearing, and an explicitly-pinned device
    /// disconnecting (falls back) or reconnecting (wins again).
    private func applyOutputRoutingToActiveRoutes() {
        let connectedUIDs = Set(devices.map(\.uid))
        for (pid, route) in activeRoutes {
            let explicit = outputDeviceUIDs[pid]
            let effective = (explicit != nil && connectedUIDs.contains(explicit!)) ? explicit : lastResolvedPriorityUID
            let sentinelValue = effective ?? Self.systemDefaultSentinel
            guard appliedOutputUID[pid] != sentinelValue else { continue }
            appliedOutputUID[pid] = sentinelValue
            rebindRouteOutput(route, pid: pid, to: effective)
        }
    }

    /// Pushes each active route's Device Levels group-volume multiplier. The deciding
    /// factor is whether this *specific route* currently has an explicit device
    /// binding at all (appliedOutputUID's sentinel means "none, following the system
    /// default via AVAudioEngine's own implicit routing") -- NOT whether that device
    /// happens to be the system default. Originally this skipped the multiplier
    /// whenever the bound device was the default, on the assumption its native
    /// CoreAudio volume would already reach it; that broke the moment the *same*
    /// device an app was explicitly pinned to (or priority-routed to) also happened to
    /// be the current default -- confirmed directly: an explicit bind -- via
    /// `kAudioOutputUnitProperty_CurrentDevice`, same call ProcessAudioRoute.
    /// startEngine makes for any non-nil outputDeviceUID -- talks straight to that
    /// device's IOProc and bypasses whatever native-volume stage the OS's implicit
    /// "current default output" path normally includes, regardless of whether the
    /// device is the default. Only a route that's *never* had an explicit UID (always
    /// started/rebound with outputDeviceUID: nil) stays on that implicit path and
    /// genuinely gets its volume from the native device property already.
    private func applyDeviceGroupMultipliers() {
        for (pid, route) in activeRoutes {
            let explicitUID = appliedOutputUID[pid]
            let multiplier: Float
            if let explicitUID, explicitUID != Self.systemDefaultSentinel {
                multiplier = deviceGroupMuted.contains(explicitUID) ? 0 : (deviceGroupVolumes[explicitUID] ?? 1.0)
            } else {
                multiplier = 1.0
            }
            guard appliedDeviceGroupMultiplier[pid] != multiplier else { continue }
            appliedDeviceGroupMultiplier[pid] = multiplier
            route.deviceGroupMultiplier = multiplier
        }
    }

    private func persistDeviceGroupState() {
        if let data = try? JSONEncoder().encode(deviceGroupVolumes) {
            UserDefaults.standard.set(data, forKey: Self.deviceGroupVolumesDefaultsKey)
        }
        UserDefaults.standard.set(Array(deviceGroupMuted), forKey: Self.deviceGroupMutedDefaultsKey)
    }

    func refresh() {
        devices = AudioDeviceManager.outputDevices()
        resolveOutputPriorityTarget()
        // Ground truth lives in the OS (volume keys, Control Center can change it
        // outside this app), so read it fresh each time rather than tracking our own
        // copy -- unlike per-app volume, which only we control. A device whose native
        // volume read fails outright (confirmed: a connected HDMI audio-extractor
        // output has no readable CoreAudio volume at all) still gets a row, falling
        // back to our own group-volume value -- that's the only "ground truth" such a
        // device has, since there's no OS-level one to read through.
        deviceLevels = devices.map { device in
            let nativeVolume = AudioDeviceManager.volume(for: device.id)
            let displayedVolume = nativeVolume ?? deviceGroupVolumes[device.uid] ?? 1.0
            return DeviceLevelRow(id: device.id, uid: device.uid, name: device.name, iconSymbolName: device.iconSymbolName,
                                   volume: displayedVolume, isMuted: AudioDeviceManager.isMuted(device.id))
        }
        refreshSystemSounds()

        let processes = AudioProcessManager.runningAudioProcesses()
        let currentPIDs = Set(processes.map(\.pid))

        for process in processes {
            missingStreak[process.pid] = 0
            guard activeRoutes[process.pid] == nil else { continue }
            seedLiveStateIfNeeded(for: process)
            startRoute(for: process)
        }

        for pid in activeRoutes.keys where !currentPIDs.contains(pid) && pid != systemSoundsPID {
            let streak = (missingStreak[pid] ?? 0) + 1
            missingStreak[pid] = streak
            if streak >= Self.missingPollsBeforeStop {
                activeRoutes[pid]?.stop()
                activeRoutes[pid] = nil
                missingStreak[pid] = nil
                appliedOutputUID[pid] = nil
                appliedDeviceGroupMultiplier[pid] = nil
            }
        }

        applyOutputRoutingToActiveRoutes()
        applyDeviceGroupMultipliers()

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
                outputDeviceUID: outputDeviceUIDs[pid] ?? AudioDeviceManager.defaultOutputDeviceUID(),
                boost: boosts[pid] ?? AppBoostPreference()
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
                appliedOutputUID[oldPID] = nil
                appliedDeviceGroupMultiplier[oldPID] = nil
            }
            systemSoundsPID = process.pid
        }

        if activeRoutes[process.pid] == nil {
            seedLiveStateIfNeeded(for: process)
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
            outputDeviceUID: outputDeviceUIDs[process.pid] ?? AudioDeviceManager.defaultOutputDeviceUID(),
            boost: boosts[process.pid] ?? AppBoostPreference()
        )
    }

    /// Loads this bundle ID's saved preference into the live pid-keyed cache, but only
    /// the first time this pid is seen this session (guarded by volumes[pid] == nil) --
    /// later live edits must win over the stale saved value for the rest of the
    /// session. Skips restoring a saved output device that's no longer actually
    /// connected, so a route doesn't fail to start over a device that's since been
    /// unplugged/disconnected -- falls through to the normal default-device behavior.
    private func seedLiveStateIfNeeded(for process: AudioProcess) {
        guard volumes[process.pid] == nil else { return }
        let saved = persistedOutputPrefs.get(process.bundleID)
        volumes[process.pid] = saved.volume
        if saved.isMuted { muted.insert(process.pid) }
        if let uid = saved.outputDeviceUID, devices.contains(where: { $0.uid == uid }) {
            outputDeviceUIDs[process.pid] = uid
        }
        boosts[process.pid] = persistedBoostPrefs.get(process.bundleID)
    }

    private func persistPreference(bundleID: String, pid: pid_t) {
        let pref = AppOutputPreference(volume: volumes[pid] ?? 1.0, isMuted: muted.contains(pid), outputDeviceUID: outputDeviceUIDs[pid])
        persistedOutputPrefs.set(pref, for: bundleID)
    }

    private func persistBoostPreference(bundleID: String, pid: pid_t) {
        persistedBoostPrefs.set(boosts[pid] ?? AppBoostPreference(), for: bundleID)
    }

    private func startRoute(for process: AudioProcess) {
        if let backoffUntil = routeStartBackoffUntil[process.pid], backoffUntil > Date() {
            return // still cooling down after a recent failure -- see routeStartBackoffUntil's doc comment
        }
        let explicit = outputDeviceUIDs[process.pid]
        let connectedUIDs = Set(devices.map(\.uid))
        let effective = (explicit != nil && connectedUIDs.contains(explicit!)) ? explicit : lastResolvedPriorityUID
        startRoute(for: process, outputDeviceUID: effective, isRetry: false)
    }

    /// Binding straight to a specific device (rather than letting it fall through to
    /// the system default) can fail outright the first time, not just silently produce
    /// no audio -- confirmed directly: every app whose capture start raced a priority-
    /// routing switch to a Bluetooth speaker failed with `kAUStartIO` on the first
    /// attempt and succeeded cleanly on a prompt second one. One retry on a fresh route
    /// (same fix as setOutputDevice's existing mute/rebind/rebind-again dance, just
    /// applied at creation time) instead of leaving the app un-routed and silently
    /// retrying the whole tap+aggregate dance from scratch every 2-second refresh.
    ///
    /// This still runs synchronously on the main thread -- see routeStartBackoffUntil's
    /// doc comment for why moving it to a background queue isn't the fix here, and
    /// routeStartBackoffUntil for what actually bounds how long a wedged device can
    /// keep blocking the UI.
    private func startRoute(for process: AudioProcess, outputDeviceUID: String?, isRetry: Bool) {
        let route = ProcessAudioRoute(process: process)
        do {
            try route.start(outputDeviceUID: outputDeviceUID)
            appliedOutputUID[process.pid] = outputDeviceUID ?? Self.systemDefaultSentinel
            route.volume = appliedVolume(for: process.pid)
            let boost = boosts[process.pid] ?? AppBoostPreference()
            route.setBoost(mode: boost.mode, percent: boost.percent)
            route.globalMultiplier = globalBoostMultiplier
            activeRoutes[process.pid] = route
            routeStartBackoffUntil[process.pid] = nil
        } catch {
            guard !isRetry, outputDeviceUID != nil else {
                ErrorLogger.shared.critical("failed to start capture for \(process.bundleID): \(error)")
                routeStartBackoffUntil[process.pid] = Date().addingTimeInterval(Self.routeStartBackoffInterval)
                return
            }
            ErrorLogger.shared.warning("retrying capture start for \(process.bundleID) after initial failure: \(error)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.startRoute(for: process, outputDeviceUID: outputDeviceUID, isRetry: true)
            }
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
        persistPreference(bundleID: row.bundleID, pid: row.id)
    }

    func toggleMute(for row: AppRow) {
        if muted.contains(row.id) {
            muted.remove(row.id)
        } else {
            muted.insert(row.id)
        }
        activeRoutes[row.id]?.volume = appliedVolume(for: row.id)
        updateRow(id: row.id) { $0.isMuted = self.muted.contains(row.id) }
        persistPreference(bundleID: row.bundleID, pid: row.id)
    }

    func setOutputDevice(_ device: AudioDevice, for row: AppRow) {
        outputDeviceUIDs[row.id] = device.uid
        updateRow(id: row.id) { $0.outputDeviceUID = device.uid }
        persistPreference(bundleID: row.bundleID, pid: row.id)
        appliedOutputUID[row.id] = device.uid // an explicit pick here always wins; keep the routing reconciler's cache in sync
        guard let route = activeRoutes[row.id] else { return }
        rebindRouteOutput(route, pid: row.id, to: device.uid)
    }

    /// Switching the output device the first time can report success before the device
    /// -- especially Bluetooth -- is actually flowing audio yet (observed directly:
    /// the first bind sometimes doesn't produce sound, but a prompt second bind always
    /// does). Rather than make the caller retry, this mutes the app, rebinds, waits for
    /// the device to settle, rebinds again to reliably catch it up, then unmutes --
    /// with pendingDeviceSwitchPIDs driving a loading indicator in place of the device
    /// icon for that window so it's visibly "in progress," not silently broken. Shared
    /// by both a manual per-app device pick and an automatic priority-routing switch
    /// (applyOutputRoutingToActiveRoutes) -- the second one is exactly what was missing
    /// this dance originally, which is what let a priority-routed app's capture fail
    /// outright instead of recovering on its own.
    private func rebindRouteOutput(_ route: ProcessAudioRoute, pid: pid_t, to uid: String?) {
        let restoreVolume = appliedVolume(for: pid)
        pendingDeviceSwitchPIDs.insert(pid)
        route.volume = 0

        do {
            try route.setOutputDevice(uid: uid)
        } catch {
            ErrorLogger.shared.warning("failed to switch output device for pid \(pid): \(error)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            if let route = self.activeRoutes[pid] {
                do {
                    try route.setOutputDevice(uid: uid)
                } catch {
                    ErrorLogger.shared.warning("failed to re-confirm output device for pid \(pid): \(error)")
                }
                route.volume = restoreVolume
            }
            self.pendingDeviceSwitchPIDs.remove(pid)
        }
    }

    /// Switches boost mode for one app. `.preset` and `.custom` keep whatever percent
    /// was last set for them (see setBoostPercent) rather than resetting it, so
    /// toggling between modes doesn't lose the value either one was tuned to.
    func setBoostMode(_ mode: BoostMode, for row: AppRow) {
        var boost = boosts[row.id] ?? AppBoostPreference()
        boost.mode = mode
        boosts[row.id] = boost
        activeRoutes[row.id]?.setBoost(mode: boost.mode, percent: boost.percent)
        updateRow(id: row.id) { $0.boost = boost }
        persistBoostPreference(bundleID: row.bundleID, pid: row.id)
    }

    /// Sets the extra-gain percentage for `.preset` or `.custom` boost and switches to
    /// that mode in the same step -- picking a preset/entering a custom value is
    /// always also the action that turns boost on with it.
    func setBoostPercent(_ percent: Double, mode: BoostMode, for row: AppRow) {
        let boost = AppBoostPreference(mode: mode, percent: percent)
        boosts[row.id] = boost
        activeRoutes[row.id]?.setBoost(mode: boost.mode, percent: boost.percent)
        updateRow(id: row.id) { $0.boost = boost }
        persistBoostPreference(bundleID: row.bundleID, pid: row.id)
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
        deviceGroupVolumes[row.uid] = volume
        persistDeviceGroupState()
        applyDeviceGroupMultipliers()
    }

    func toggleDeviceMute(for row: DeviceLevelRow) {
        let newMuted = !row.isMuted
        AudioDeviceManager.setMuted(newMuted, for: row.id)
        if let index = deviceLevels.firstIndex(where: { $0.id == row.id }) {
            deviceLevels[index].isMuted = newMuted
        }
        if newMuted {
            deviceGroupMuted.insert(row.uid)
        } else {
            deviceGroupMuted.remove(row.uid)
        }
        persistDeviceGroupState()
        applyDeviceGroupMultipliers()
    }

    func shutdown() {
        for route in activeRoutes.values { route.stop() }
        activeRoutes.removeAll()
    }
}
