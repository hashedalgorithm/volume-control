import AVFoundation
import AppKit
import CoreAudio
import Foundation

/// UID of the HAL plugin from HALPlugin/VolumeControlMicMix.driver (see
/// docs/install-micmix.md) -- must match kDeviceUID in VolumeControlMicMix.c exactly.
private let micMixDeviceUID = "com.volumecontrol.micmix"

/// Fixed format every captured source gets resampled to before being summed -- matches
/// VolumeControlMicMix.c's own device format exactly (48kHz, 2ch, Float32). Normalizing
/// at the capture boundary (via AVAudioConverter, right as each source's IOProc writes
/// into its ring buffer) means the actual mix is a trivial frame-for-frame sum with no
/// sample-rate or channel-count mismatch to reason about at mix time -- this is also
/// closer to how the OS's own system-audio+mic mixing works (aggregate devices/taps
/// normalized to one clock, summed, not pushed through a node-graph mixer). Replaces an
/// earlier AVAudioEngine mainMixerNode approach: connecting a new app source to an
/// already-running engine measurably changed the mixer's own resolved output format
/// (44100 Hz -> 48000 Hz observed directly in one capture), and that source's audio
/// never reached the far end of a real call even though its own capture was verified
/// healthy -- a stop/restart-the-engine workaround helped but didn't fully resolve it
/// over a live call, so the node-graph mixing step was removed rather than patched
/// further.
private let mixTargetSampleRate: Double = 48000
private let mixTargetChannelCount: AVAudioChannelCount = 2
private func makeMixTargetFormat() -> AVAudioFormat {
    AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: mixTargetSampleRate,
                  channels: mixTargetChannelCount, interleaved: false)!
}

/// Converts one just-captured buffer to the shared mix target format. Each call site
/// (one per source) owns its own AVAudioConverter -- resampling/channel-mapping state
/// can't be shared across independent sources.
private func convertToMixTarget(_ source: AVAudioPCMBuffer, using converter: AVAudioConverter, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
    guard source.frameLength > 0 else { return nil }
    let ratio = targetFormat.sampleRate / source.format.sampleRate
    let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 64 // safety margin
    guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
    var provided = false
    var conversionError: NSError?
    converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
        if provided {
            outStatus.pointee = .noDataNow
            return nil
        }
        provided = true
        outStatus.pointee = .haveData
        return source
    }
    guard conversionError == nil, outBuffer.frameLength > 0 else { return nil }
    return outBuffer
}

/// Capture-only tap for one app's audio, feeding InputMixEngine's own manual mix rather
/// than its own playback engine. Deliberately duplicates ProcessAudioRoute's
/// tap/aggregate/format-query/IOProc setup instead of sharing code with it --
/// ProcessAudioRoute took several iterations to get right (sample-rate and
/// interleaving bugs) and is now working for the Output tab; refactoring it to serve
/// two different call sites risked regressing that for a net-smaller amount of shared
/// code.
@available(macOS 14.2, *)
private final class MicMixAppSource {
    let process: AudioProcess
    let ringBuffer = AudioRingBuffer(capacityFrames: 1 << 16, maxLatencyFrames: defaultRingBufferLatencyFrames)
    private(set) var captureFormat = AudioStreamBasicDescription()

    private var tapID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var nativeFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat?

    init(process: AudioProcess) {
        self.process = process
    }

    func start() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: [process.id])
        description.name = "VolumeControl-micmix-tap-\(process.pid)"
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.muted

        var newTapID: AudioObjectID = 0
        try AudioDeviceManager.check(AudioHardwareCreateProcessTap(description, &newTapID), "create process tap")
        tapID = newTapID
        let tapUUID = description.uuid.uuidString

        let dict: [String: Any] = [
            kAudioAggregateDeviceUIDKey: "com.volumecontrol.micmixtap.\(process.pid).\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUUID, kAudioSubTapDriftCompensationKey: true]
            ]
        ]
        var newAggregateID: AudioObjectID = 0
        try AudioDeviceManager.check(
            AudioHardwareCreateAggregateDevice(dict as CFDictionary, &newAggregateID),
            "create mic-mix tap aggregate device"
        )
        aggregateDeviceID = newAggregateID

        captureFormat = try queryCaptureFormat()
        guard let native = AVAudioFormat(streamDescription: &captureFormat) else {
            throw CoreAudioError.osStatus(kAudio_ParamError, "could not describe captured format")
        }
        nativeFormat = native
        let targetFormat = makeMixTargetFormat()
        self.targetFormat = targetFormat
        guard let converter = AVAudioConverter(from: native, to: targetFormat) else {
            throw CoreAudioError.osStatus(kAudio_ParamError, "could not build app source format converter")
        }
        // See the matching comment in InputMixEngine.startMicCapture -- a channel
        // COUNT change (not just sample rate) needs an explicit map or the conversion
        // silently produces nothing. Apps are mixed down to stereo by the tap itself
        // (stereoMixdownOfProcesses) so this shouldn't normally fire, but guarding it
        // the same way keeps this source from going silently dead the way mic capture
        // did if that ever changes.
        if native.channelCount != targetFormat.channelCount {
            converter.channelMap = (0..<Int(targetFormat.channelCount)).map { NSNumber(value: min($0, Int(native.channelCount) - 1)) }
        }
        self.converter = converter

        try startIOProc()
    }

    func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        ioProcID = nil
        if aggregateDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }

    deinit { stop() }

    private func queryCaptureFormat() throws -> AudioStreamBasicDescription {
        var streamsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        try AudioDeviceManager.check(
            AudioObjectGetPropertyDataSize(aggregateDeviceID, &streamsAddress, 0, nil, &dataSize),
            "get tap aggregate input stream list size"
        )
        var streamIDs = [AudioObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        try AudioDeviceManager.check(
            AudioObjectGetPropertyData(aggregateDeviceID, &streamsAddress, 0, nil, &dataSize, &streamIDs),
            "get tap aggregate input streams"
        )
        guard let streamID = streamIDs.first else {
            throw CoreAudioError.osStatus(kAudio_ParamError, "tap aggregate device has no input stream")
        }
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try AudioDeviceManager.check(
            AudioObjectGetPropertyData(streamID, &formatAddress, 0, nil, &formatSize, &format),
            "get tap stream format"
        )
        return format
    }

    private func startIOProc() throws {
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, nil) { [weak self] _, inInputData, _, _, _ in
            guard let self, let native = self.nativeFormat, let converter = self.converter, let targetFormat = self.targetFormat else { return }
            guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: native, bufferListNoCopy: inInputData) else { return }
            guard let converted = convertToMixTarget(sourceBuffer, using: converter, targetFormat: targetFormat) else { return }
            self.ringBuffer.write(from: converted.audioBufferList)
        }
        try AudioDeviceManager.check(status, "create mic-mix tap IOProc")
        ioProcID = procID
        try AudioDeviceManager.check(AudioDeviceStart(aggregateDeviceID, procID), "start mic-mix tap IOProc")
    }
}

struct MicMixAppRow: Identifiable, Equatable {
    let id: pid_t
    let bundleID: String
    let name: String
    let icon: NSImage
    var isIncluded: Bool
    var mixVolume: Float
}

private let micSensitivityDefaultsKey = "inputMicSensitivity"
private let micMutedDefaultsKey = "inputMicMuted"

/// Input tab's model: mixes the real microphone (gain-controllable, instantly mutable)
/// with zero or more selected apps' audio, and writes the result into the "Volume
/// Control Mic Mix" virtual device -- call apps that select it as their input hear the
/// mix, no manual window-finding/audibility-checking during a call.
///
/// Mixing is done manually, sample-by-sample, in a dedicated output IOProc bound
/// directly to the virtual device (see renderMix) -- not via AVAudioEngine's
/// mainMixerNode (see the file-level comment on mixTargetSampleRate for why that was
/// replaced). Each source (mic, each included app) already writes pre-resampled,
/// pre-channel-mapped 48kHz/2ch Float32 into its own ring buffer; the output IOProc
/// reads frameCount frames from each, scales by that source's volume, sums, soft-limits
/// to prevent clipping, and writes the interleaved result straight to the device. That
/// keeps the HAL plugin itself a plain single-writer ring buffer (see
/// HALPlugin/src/VolumeControlMicMix.c).
@available(macOS 14.2, *)
final class InputMixEngine: ObservableObject {
    @Published private(set) var isDeviceInstalled = false
    /// Explicit master on/off for the whole input-mixing setup -- off by default.
    /// Nothing touches the microphone (no capture, no permission prompt) until this is
    /// turned on; turning it off fully stops mic capture and every included app's tap,
    /// it doesn't just mute them. Previously this started automatically the first time
    /// the Input tab was viewed and then ran forever in the background, which is what
    /// was picking up and passing through typing noise etc. with no way to stop it
    /// short of quitting the app.
    @Published private(set) var isEnabled = false
    @Published var micSensitivity: Float = 1.0 {
        didSet {
            UserDefaults.standard.set(micSensitivity, forKey: micSensitivityDefaultsKey)
        }
    }
    @Published private(set) var isMicMuted = false
    @Published private(set) var apps: [MicMixAppRow] = []
    @Published private(set) var isInstalling = false
    @Published var installError: String?

    private let micRingBuffer = AudioRingBuffer(capacityFrames: 1 << 16, maxLatencyFrames: defaultRingBufferLatencyFrames)
    /// Raw CoreAudio IOProc bound directly to the real mic's AudioDeviceID -- not
    /// AVAudioEngine. See startMicCapture's own comment for why: AVAudioEngine's input
    /// node either gets the hardware's raw, unprocessed multi-element array signal
    /// (when explicitly pinned to a device) or silently re-resolves to whatever the
    /// system default input currently is, including our own virtual mic-mix device
    /// once setEnabled switches the default to it (a real, confirmed feedback loop,
    /// not a hypothetical) -- both tried, both failed. A plain device-bound IOProc,
    /// the same mechanism the per-app taps already use successfully all session with
    /// neither problem, sidesteps both: it reads a specific device directly and never
    /// re-resolves based on system default changes.
    private var micIOProcID: AudioDeviceIOProcID?
    private var micDeviceID: AudioDeviceID = 0

    private var appSources: [pid_t: MicMixAppSource] = [:]
    /// Live, in-session cache -- pids are a new random number every process launch.
    private var includedApps: Set<pid_t> = []
    private var mixVolumes: [pid_t: Float] = [:]
    private var missingStreak: [pid_t: Int] = [:]
    private var refreshTimer: Timer?
    /// The system default input device from just before setEnabled(true) switched it
    /// to the mic-mix virtual device, so setEnabled(false) can hand it back.
    private var previousDefaultInputDeviceUID: String?
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?
    /// The actual persisted store, keyed by bundle ID. Does NOT include the master
    /// isEnabled switch itself -- that deliberately always starts off (see setEnabled),
    /// so a restart never silently resumes microphone capture.
    private let persistedMixPrefs = PersistedStore<AppMixPreference>(
        defaultsKey: "inputMixAppPreferences", defaultValue: AppMixPreference()
    )

    // MARK: - Manual mix (output IOProc)

    private struct LiveMixSource {
        let ringBuffer: AudioRingBuffer
        let volume: Float
    }
    private var mixOutputIOProcID: AudioDeviceIOProcID?
    private var mixOutputDeviceID: AudioDeviceID = 0
    /// Rebuilt (under mixLock) on every addAppSource/removeAppSource/setMixVolume --
    /// the render callback reads this snapshot instead of touching appSources/
    /// mixVolumes directly, so it's never racing a Dictionary mutation happening on
    /// the main thread mid-iteration.
    private var liveMixSources: [LiveMixSource] = []
    private let mixLock = NSLock()
    private static let maxFramesPerCallback = 4096
    private var micScratch = [[Float]](repeating: [Float](repeating: 0, count: maxFramesPerCallback), count: Int(mixTargetChannelCount))
    private var appScratch = [[Float]](repeating: [Float](repeating: 0, count: maxFramesPerCallback), count: Int(mixTargetChannelCount))
    private var accumScratch = [[Float]](repeating: [Float](repeating: 0, count: maxFramesPerCallback), count: Int(mixTargetChannelCount))
    private var mixDebugTick = 0

    private static let genericAppIcon = NSWorkspace.shared.icon(for: .application)
    private static let missingPollsBeforeStop = 3

    init() {
        if UserDefaults.standard.object(forKey: micSensitivityDefaultsKey) != nil {
            micSensitivity = UserDefaults.standard.float(forKey: micSensitivityDefaultsKey)
        }
        isMicMuted = UserDefaults.standard.bool(forKey: micMutedDefaultsKey)

        refreshDeviceAvailability()
        // Always-on lightweight polling: device-installed status and the list of apps
        // currently playing audio. Neither touches the mic or starts anything -- that
        // only happens via setEnabled(true), an explicit user action.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// The master on/off switch. Turning on starts mic capture (first time: triggers
    /// the mic permission prompt) and the mix output, and attaches any apps already
    /// marked included. Turning off fully tears all of that down -- app selections and
    /// mic sensitivity are kept so turning back on restores the prior setup instantly.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            guard isDeviceInstalled else { return }
            do {
                try start()
                isEnabled = true
                for pid in includedApps where appSources[pid] == nil {
                    if let process = AudioProcessManager.runningAudioProcesses().first(where: { $0.pid == pid }) {
                        try? addAppSource(process)
                    }
                }
                // The mix output doesn't by itself make any app (a call app, say)
                // actually listen to it -- apps just use whatever the system's default
                // input is. Switching it here is what makes turning this on actually
                // take effect for a call without a separate manual trip to Sound
                // settings; remembered so it can be restored on the way back off.
                previousDefaultInputDeviceUID = AudioDeviceManager.defaultInputDeviceUID()
                claimDefaultInputDevice()
                startWatchingDefaultInputDevice()
            } catch {
                debugProbeAppend("failed to start input mix engine: \(error)")
            }
        } else {
            isEnabled = false
            stopWatchingDefaultInputDevice()
            stopEngineAndSources()
            // Only restore it if it's still actually connected -- forcing the
            // default back onto a device that's since been unplugged would just
            // leave the user with no working input at all.
            debugProbeAppend("setEnabled(false) restore: previousUID=\(previousDefaultInputDeviceUID ?? "nil")")
            if let uid = previousDefaultInputDeviceUID, let deviceID = AudioDeviceManager.deviceID(forUID: uid) {
                let ok = AudioDeviceManager.setDefaultInputDevice(deviceID)
                debugProbeAppend("setEnabled(false) restore result=\(ok) deviceID=\(deviceID)")
            }
            previousDefaultInputDeviceUID = nil
        }
    }

    /// Sets the mic-mix virtual device as the system default input. Observed directly
    /// (coreaudiod's own log confirmed the SetData call, yet AudioObjectGetPropertyData
    /// read back the old device moments later): the very first attempt, made right as
    /// the capture engine is still finishing starting, doesn't reliably stick -- same
    /// class of race as setOutputDevice's retry dance elsewhere in this app, just on
    /// the input side. A short delayed re-apply catches that; startWatchingDefaultInputDevice
    /// below catches anything that reverts it afterwards, for as long as this stays on.
    private func claimDefaultInputDevice() {
        guard let micMixDeviceID = AudioDeviceManager.deviceID(forUID: micMixDeviceUID) else { return }
        AudioDeviceManager.setDefaultInputDevice(micMixDeviceID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.isEnabled else { return }
            if AudioDeviceManager.defaultInputDeviceUID() != micMixDeviceUID {
                AudioDeviceManager.setDefaultInputDevice(micMixDeviceID)
            }
        }
    }

    private func startWatchingDefaultInputDevice() {
        guard defaultInputListenerBlock == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.isEnabled else { return }
            if AudioDeviceManager.defaultInputDeviceUID() != micMixDeviceUID {
                self.claimDefaultInputDevice()
            }
        }
        defaultInputListenerBlock = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }

    private func stopWatchingDefaultInputDevice() {
        guard let block = defaultInputListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        defaultInputListenerBlock = nil
    }

    func refresh() {
        refreshDeviceAvailability()

        let processes = AudioProcessManager.runningAudioProcesses()
        let currentPIDs = Set(processes.map(\.pid))

        for process in processes {
            seedLiveStateIfNeeded(for: process)
        }

        if isEnabled {
            for pid in Array(appSources.keys) where !currentPIDs.contains(pid) {
                let streak = (missingStreak[pid] ?? 0) + 1
                missingStreak[pid] = streak
                if streak >= Self.missingPollsBeforeStop {
                    removeAppSource(pid: pid)
                }
            }
            for process in processes where includedApps.contains(process.pid) {
                missingStreak[process.pid] = 0
                if appSources[process.pid] == nil {
                    do {
                        try addAppSource(process)
                    } catch {
                        debugProbeAppend("failed to add mic-mix source for \(process.bundleID): \(error)")
                    }
                }
            }
        }

        apps = processes.map { process in
            let running = NSRunningApplication(processIdentifier: process.pid)
            return MicMixAppRow(
                id: process.pid,
                bundleID: process.bundleID,
                name: running?.localizedName ?? process.bundleID,
                icon: running?.icon ?? Self.genericAppIcon,
                isIncluded: includedApps.contains(process.pid),
                mixVolume: mixVolumes[process.pid] ?? 1.0
            )
        }.sorted { $0.name < $1.name }
    }

    /// Seeds this pid's live cache from the bundle-ID-keyed persisted store the first
    /// time it's seen this session -- mirrors AudioMixerModel.seedLiveStateIfNeeded(for:).
    /// Does NOT start capture by itself even if isIncluded was persisted true; that only
    /// happens once the master switch is explicitly turned on (see setEnabled), which
    /// then attaches sources for everything already in includedApps.
    private func seedLiveStateIfNeeded(for process: AudioProcess) {
        guard mixVolumes[process.pid] == nil else { return }
        let saved = persistedMixPrefs.get(process.bundleID)
        mixVolumes[process.pid] = saved.mixVolume
        if saved.isIncluded {
            includedApps.insert(process.pid)
        }
    }

    private func persistMixPreference(bundleID: String, pid: pid_t) {
        let pref = AppMixPreference(isIncluded: includedApps.contains(pid), mixVolume: mixVolumes[pid] ?? 1.0)
        persistedMixPrefs.set(pref, for: bundleID)
    }

    /// Toggling inclusion works whether or not the master switch is on -- if off, this
    /// just records the selection for when it's turned on; if on, it takes effect
    /// immediately.
    func toggleInclude(for row: MicMixAppRow) {
        if includedApps.contains(row.id) {
            includedApps.remove(row.id)
            if isEnabled { removeAppSource(pid: row.id) }
        } else {
            includedApps.insert(row.id)
            if isEnabled, let process = AudioProcessManager.runningAudioProcesses().first(where: { $0.pid == row.id }) {
                do {
                    try addAppSource(process)
                } catch {
                    debugProbeAppend("failed to add mic-mix source for \(process.bundleID): \(error)")
                }
            }
        }
        persistMixPreference(bundleID: row.bundleID, pid: row.id)
        refresh()
    }

    func setMixVolume(_ volume: Float, for row: MicMixAppRow) {
        mixVolumes[row.id] = volume
        if let index = apps.firstIndex(where: { $0.id == row.id }) {
            apps[index].mixVolume = volume
        }
        rebuildLiveMixSources()
        persistMixPreference(bundleID: row.bundleID, pid: row.id)
    }

    func toggleMicMute() {
        isMicMuted.toggle()
        UserDefaults.standard.set(isMicMuted, forKey: micMutedDefaultsKey)
    }

    func shutdown() {
        refreshTimer?.invalidate()
        isEnabled = false
        stopWatchingDefaultInputDevice()
        stopEngineAndSources()
        // Quitting (or this object being torn down) while mixing was on must hand
        // the system back its real input device too -- otherwise the user's left
        // with no working microphone until they notice and fix it manually, same
        // as if setEnabled(false) had never run its own restore step below.
        debugProbeAppend("shutdown() restore: previousUID=\(previousDefaultInputDeviceUID ?? "nil")")
        if let uid = previousDefaultInputDeviceUID, let deviceID = AudioDeviceManager.deviceID(forUID: uid) {
            let ok = AudioDeviceManager.setDefaultInputDevice(deviceID)
            debugProbeAppend("shutdown() restore result=\(ok) deviceID=\(deviceID)")
        }
        previousDefaultInputDeviceUID = nil
    }

    deinit { shutdown() }

    private func stopEngineAndSources() {
        for pid in Array(appSources.keys) { removeAppSource(pid: pid) }
        stopMicCaptureIOProc()
        stopMixOutputIOProc()
    }

    private func stopMicCaptureIOProc() {
        if let procID = micIOProcID, micDeviceID != 0 {
            AudioDeviceStop(micDeviceID, procID)
            AudioDeviceDestroyIOProcID(micDeviceID, procID)
        }
        micIOProcID = nil
        micDeviceID = 0
    }

    // MARK: - Setup

    private func refreshDeviceAvailability() {
        isDeviceInstalled = MicMixInstaller.isInstalled()
    }

    /// Runs the install on a background thread since it blocks on the admin-password
    /// prompt; updates published state back on the main thread when it resolves.
    func installVirtualDevice() {
        guard !isInstalling else { return }
        isInstalling = true
        installError = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try MicMixInstaller.install()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isInstalling = false
                    self.refreshDeviceAvailability()
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isInstalling = false
                    self?.installError = error.localizedDescription
                }
            }
        }
    }

    private static let debugTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// Debug-only instrumentation (compiles to nothing in Release) -- writes to a
    /// fixed /tmp path rather than NSLog, which was confirmed unreliable for this
    /// code path (entries didn't show up in `log show` even when the code
    /// demonstrably ran). Gated on #if DEBUG rather than relying on remembering to
    /// comment call sites out before each release build.
    private func debugProbeAppend(_ line: String) {
        #if DEBUG
        let path = "/tmp/vc-debug-probe.log"
        let timestamp = Self.debugTimeFormatter.string(from: Date())
        guard let data = ("\(timestamp) \(line)\n").data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
        #endif
    }

    private func start() throws {
        debugProbeAppend("start() called")
        guard let micMixDeviceID = AudioDeviceManager.deviceID(forUID: micMixDeviceUID) else {
            throw CoreAudioError.osStatus(kAudio_ParamError, "mic mix device not found")
        }

        // Resolved once here, before setEnabled's caller switches the system default
        // input over to the mic-mix device -- startMicCapture below binds directly to
        // this specific AudioDeviceID via a raw IOProc, not AVAudioEngine's "current
        // default" resolution, so later default-input changes (including our own)
        // can't redirect it. Still guarding against ever resolving to the mic-mix
        // device itself here, though: an unclean previous session could leave the
        // system default already pointed at it before this even runs.
        var realMicDeviceID = AudioDeviceManager.defaultInputDeviceID()
        if realMicDeviceID == nil || realMicDeviceID == micMixDeviceID {
            guard let fallback = AudioDeviceManager.inputDevices().first else {
                throw CoreAudioError.osStatus(kAudio_ParamError, "no real (non-virtual) input device found")
            }
            debugProbeAppend("default input was mic-mix itself or missing -- falling back to \(fallback.name)")
            realMicDeviceID = fallback.id
        }
        try startMicCapture(on: realMicDeviceID!)
        try startMixOutputIOProc(deviceID: micMixDeviceID)
        debugProbeAppend("mix output IOProc started")
    }

    /// Raw CoreAudio IOProc bound directly to `deviceID` -- not AVAudioEngine. See the
    /// stored-property comment on micIOProcID for why: both ways of going through
    /// AVAudioEngine that were tried (explicit device pin, or left unbound to follow
    /// the system default) failed in different ways. This mirrors MicMixAppSource's
    /// own IOProc exactly, just reading a real hardware device directly instead of a
    /// process tap's aggregate device -- the same mechanism that's run all session
    /// with neither the raw-array-channel problem nor the default-following one.
    private func startMicCapture(on deviceID: AudioDeviceID) throws {
        var nativeFormatDescription = try queryInputStreamFormat(deviceID: deviceID)
        guard let native = AVAudioFormat(streamDescription: &nativeFormatDescription) else {
            throw CoreAudioError.osStatus(kAudio_ParamError, "could not describe mic capture format")
        }
        debugProbeAppend("mic native format (direct device IOProc)=\(native)")

        let targetFormat = makeMixTargetFormat()
        guard let converter = AVAudioConverter(from: native, to: targetFormat) else {
            throw CoreAudioError.osStatus(kAudio_ParamError, "could not build mic format converter")
        }
        if native.channelCount != targetFormat.channelCount {
            converter.channelMap = [NSNumber](repeating: 0, count: Int(targetFormat.channelCount))
        }

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { [micRingBuffer] _, inInputData, _, _, _ in
            guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: native, bufferListNoCopy: inInputData) else { return }
            guard let converted = convertToMixTarget(sourceBuffer, using: converter, targetFormat: targetFormat) else { return }
            micRingBuffer.write(from: converted.audioBufferList)
        }
        try AudioDeviceManager.check(status, "create mic capture IOProc")
        micIOProcID = procID
        micDeviceID = deviceID
        try AudioDeviceManager.check(AudioDeviceStart(deviceID, procID), "start mic capture IOProc")
        debugProbeAppend("mic capture IOProc started on device=\(deviceID)")
    }

    /// Mirrors MicMixAppSource.queryCaptureFormat() -- same query, just against a real
    /// device's own input stream instead of a tap aggregate's.
    private func queryInputStreamFormat(deviceID: AudioDeviceID) throws -> AudioStreamBasicDescription {
        var streamsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        try AudioDeviceManager.check(
            AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, nil, &dataSize),
            "get mic input stream list size"
        )
        var streamIDs = [AudioObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        try AudioDeviceManager.check(
            AudioObjectGetPropertyData(deviceID, &streamsAddress, 0, nil, &dataSize, &streamIDs),
            "get mic input streams"
        )
        guard let streamID = streamIDs.first else {
            throw CoreAudioError.osStatus(kAudio_ParamError, "mic device has no input stream")
        }
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try AudioDeviceManager.check(
            AudioObjectGetPropertyData(streamID, &formatAddress, 0, nil, &formatSize, &format),
            "get mic stream format"
        )
        return format
    }

    private func addAppSource(_ process: AudioProcess) throws {
        let source = MicMixAppSource(process: process)
        try source.start()
        appSources[process.pid] = source
        rebuildLiveMixSources()
        debugProbeAppend("addAppSource(\(process.bundleID)) started, volume=\(mixVolumes[process.pid] ?? 1.0)")
    }

    private func removeAppSource(pid: pid_t) {
        let bundleID = appSources[pid]?.process.bundleID ?? "pid \(pid)"
        appSources[pid]?.stop()
        appSources[pid] = nil
        missingStreak[pid] = nil
        rebuildLiveMixSources()
        debugProbeAppend("removeAppSource(\(bundleID)) stopped, remaining=\(appSources.count)")
    }

    /// Snapshot of (ringBuffer, volume) for every currently-included app source, read
    /// by renderMix under mixLock -- rebuilt here (under the same lock) whenever
    /// sources or volumes change, so the real-time render callback never touches
    /// appSources/mixVolumes (plain Dictionaries, not safe to mutate on one thread
    /// while iterating on another) directly.
    private func rebuildLiveMixSources() {
        let snapshot = appSources.values.map { source in
            LiveMixSource(ringBuffer: source.ringBuffer, volume: mixVolumes[source.process.pid] ?? 1.0)
        }
        mixLock.lock()
        liveMixSources = snapshot
        mixLock.unlock()
    }

    // MARK: - Output (manual mix -> mic-mix device)

    private func startMixOutputIOProc(deviceID: AudioDeviceID) throws {
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { [weak self] _, _, _, outOutputData, _ in
            guard let self else { return }
            self.renderMix(into: outOutputData)
        }
        try AudioDeviceManager.check(status, "create mix output IOProc")
        mixOutputDeviceID = deviceID
        mixOutputIOProcID = procID
        try AudioDeviceManager.check(AudioDeviceStart(deviceID, procID), "start mix output IOProc")
    }

    private func stopMixOutputIOProc() {
        if let procID = mixOutputIOProcID, mixOutputDeviceID != 0 {
            AudioDeviceStop(mixOutputDeviceID, procID)
            AudioDeviceDestroyIOProcID(mixOutputDeviceID, procID)
        }
        mixOutputIOProcID = nil
        mixOutputDeviceID = 0
    }

    /// The actual mix: reads frameCount frames from the mic's ring buffer and every
    /// included app's ring buffer (all already normalized to mixTargetSampleRate/
    /// mixTargetChannelCount at capture time -- see the file-level comment), scales
    /// each by its own volume, sums sample-by-sample, soft-limits with tanh (a smooth
    /// saturating curve rather than hard digital clipping -- raw captured peaks were
    /// measured hitting 0.96-1.15 before this existed, well past full scale), and
    /// writes the interleaved stereo result straight into the device's output buffer.
    private func renderMix(into outputData: UnsafeMutablePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(outputData)
        guard let outBuffer = abl.first, let outData = outBuffer.mData?.assumingMemoryBound(to: Float.self) else { return }
        let channelCount = Int(mixTargetChannelCount)
        let requestedFrames = Int(outBuffer.mDataByteSize) / MemoryLayout<Float>.size / channelCount
        let frames = min(requestedFrames, Self.maxFramesPerCallback)

        micRingBuffer.read(frameCount: frames, intoChannels: &micScratch)
        let micGain = isMicMuted ? 0 : micSensitivity
        var micPeak: Float = 0
        for ch in 0..<channelCount {
            for i in 0..<frames {
                let scaled = micScratch[ch][i] * micGain
                accumScratch[ch][i] = scaled
                micPeak = max(micPeak, abs(scaled))
            }
        }

        mixLock.lock()
        let sources = liveMixSources
        mixLock.unlock()

        // Per-source breakdown (not just the combined total) -- needed to tell apart
        // "this source isn't being captured" from "it's captured but too quiet
        // relative to the others to actually hear," which the combined peak alone
        // can't distinguish.
        var appPeakTotal: Float = 0
        for source in sources {
            source.ringBuffer.read(frameCount: frames, intoChannels: &appScratch)
            let volume = source.volume
            var sourcePeak: Float = 0
            for ch in 0..<channelCount {
                for i in 0..<frames {
                    let scaled = appScratch[ch][i] * volume
                    accumScratch[ch][i] += scaled
                    sourcePeak = max(sourcePeak, abs(scaled))
                }
            }
            appPeakTotal = max(appPeakTotal, sourcePeak)
        }

        var peak: Float = 0
        for i in 0..<frames {
            for ch in 0..<channelCount {
                let limited = tanhf(accumScratch[ch][i])
                outData[i * channelCount + ch] = limited
                peak = max(peak, abs(limited))
            }
        }
        if requestedFrames > frames {
            for i in (frames * channelCount)..<(requestedFrames * channelCount) { outData[i] = 0 }
        }

        mixDebugTick += 1
        if mixDebugTick % 50 == 0 {
            let p = peak
            let mp = micPeak
            let ap = appPeakTotal
            let sourceCount = sources.count
            DispatchQueue.main.async { [weak self] in
                self?.debugProbeAppend("MIX OUTPUT peak=\(p) mic=\(mp) app=\(ap) sources=\(sourceCount)")
            }
        }
    }
}
