import AVFoundation
import AppKit
import CoreAudio
import Foundation

/// UID of the HAL plugin from HALPlugin/VolumeControlMicMix.driver (see
/// docs/install-micmix.md) -- must match kDeviceUID in VolumeControlMicMix.c exactly.
private let micMixDeviceUID = "com.volumecontrol.micmix"

/// Capture-only tap for one app's audio, feeding InputMixEngine's shared mixer rather
/// than its own playback engine. Deliberately duplicates ProcessAudioRoute's
/// tap/aggregate/format-query/IOProc setup instead of sharing code with it --
/// ProcessAudioRoute took several iterations to get right (sample-rate and
/// interleaving bugs) and is now working for the Output tab; refactoring it to serve
/// two different call sites risked regressing that for a net-smaller amount of shared
/// code.
@available(macOS 14.2, *)
private final class MicMixAppSource {
    let process: AudioProcess
    let ringBuffer = AudioRingBuffer(capacityFrames: 1 << 16)
    private(set) var captureFormat = AudioStreamBasicDescription()

    private var tapID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?

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

    var sourceFormat: AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: captureFormat.mSampleRate,
                      channels: AVAudioChannelCount(captureFormat.mChannelsPerFrame), interleaved: false)
    }

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
            guard let self else { return }
            let format = self.captureFormat
            let isInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
            let channelCount = Int(format.mChannelsPerFrame)
            if isInterleaved {
                let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
                guard let buffer = abl.first, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
                let frameCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / max(channelCount, 1)
                self.ringBuffer.writeInterleaved(data, frameCount: frameCount, channelCount: channelCount)
            } else {
                self.ringBuffer.write(from: inInputData)
            }
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
/// One AVAudioEngine (`engine`) bound to the virtual device's output does the mixing:
/// a mic source node plus one source node per included app all connect into
/// mainMixerNode, which feeds the single virtual-device output connection. That keeps
/// the HAL plugin itself a plain single-writer ring buffer (see
/// HALPlugin/src/VolumeControlMicMix.c) -- all the mixing happens here, not in the
/// driver.
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
            applyMicVolume()
            UserDefaults.standard.set(micSensitivity, forKey: micSensitivityDefaultsKey)
        }
    }
    @Published private(set) var isMicMuted = false
    @Published private(set) var apps: [MicMixAppRow] = []
    @Published private(set) var isInstalling = false
    @Published var installError: String?

    private let engine = AVAudioEngine()
    private let micCaptureEngine = AVAudioEngine()
    private let micRingBuffer = AudioRingBuffer(capacityFrames: 1 << 16)
    private var micSourceNode: AVAudioSourceNode?

    private var appSources: [pid_t: MicMixAppSource] = [:]
    private var appSourceNodes: [pid_t: AVAudioSourceNode] = [:]
    /// Live, in-session cache -- pids are a new random number every process launch.
    private var includedApps: Set<pid_t> = []
    private var mixVolumes: [pid_t: Float] = [:]
    private var missingStreak: [pid_t: Int] = [:]
    private var refreshTimer: Timer?
    /// The actual persisted store, keyed by bundle ID. Does NOT include the master
    /// isEnabled switch itself -- that deliberately always starts off (see setEnabled),
    /// so a restart never silently resumes microphone capture.
    private let persistedMixPrefs = PersistedStore<AppMixPreference>(
        defaultsKey: "inputMixAppPreferences", defaultValue: AppMixPreference()
    )

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
    /// the mic permission prompt) and the engine, and attaches any apps already marked
    /// included. Turning off fully tears all of that down -- app selections and mic
    /// sensitivity are kept so turning back on restores the prior setup instantly.
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
            } catch {
                NSLog("VolumeControl: failed to start input mix engine: \(error)")
            }
        } else {
            isEnabled = false
            stopEngineAndSources()
        }
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
                        NSLog("VolumeControl: failed to add mic-mix source for \(process.bundleID): \(error)")
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
                    NSLog("VolumeControl: failed to add mic-mix source for \(process.bundleID): \(error)")
                }
            }
        }
        persistMixPreference(bundleID: row.bundleID, pid: row.id)
        refresh()
    }

    func setMixVolume(_ volume: Float, for row: MicMixAppRow) {
        mixVolumes[row.id] = volume
        appSourceNodes[row.id]?.volume = volume
        if let index = apps.firstIndex(where: { $0.id == row.id }) {
            apps[index].mixVolume = volume
        }
        persistMixPreference(bundleID: row.bundleID, pid: row.id)
    }

    func toggleMicMute() {
        isMicMuted.toggle()
        applyMicVolume()
        UserDefaults.standard.set(isMicMuted, forKey: micMutedDefaultsKey)
    }

    func shutdown() {
        refreshTimer?.invalidate()
        isEnabled = false
        stopEngineAndSources()
    }

    deinit { shutdown() }

    private func stopEngineAndSources() {
        for pid in Array(appSources.keys) { removeAppSource(pid: pid) }
        micCaptureEngine.inputNode.removeTap(onBus: 0)
        micCaptureEngine.stop()
        engine.stop()
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

    private func start() throws {
        guard let deviceID = AudioDeviceManager.deviceID(forUID: micMixDeviceUID) else {
            throw CoreAudioError.osStatus(kAudio_ParamError, "mic mix device not found")
        }
        guard let outputAudioUnit = engine.outputNode.audioUnit else {
            throw CoreAudioError.osStatus(kAudio_ParamError, "engine has no output audio unit")
        }
        var mutableDeviceID = deviceID
        try AudioDeviceManager.check(
            AudioUnitSetProperty(outputAudioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                  &mutableDeviceID, UInt32(MemoryLayout<AudioDeviceID>.size)),
            "bind engine output to mic mix device"
        )

        try startMicCapture()
        try engine.start()
    }

    private func startMicCapture() throws {
        let inputNode = micCaptureEngine.inputNode
        let micFormat = inputNode.inputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: micFormat) { [micRingBuffer] buffer, _ in
            micRingBuffer.write(from: buffer.audioBufferList)
        }
        try micCaptureEngine.start()

        let node = AVAudioSourceNode(format: micFormat) { [micRingBuffer] _, _, frameCount, audioBufferList -> OSStatus in
            micRingBuffer.read(frameCount: Int(frameCount), into: audioBufferList)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: micFormat)
        micSourceNode = node
        applyMicVolume()
    }

    private func applyMicVolume() {
        micSourceNode?.volume = isMicMuted ? 0 : micSensitivity
    }

    private func addAppSource(_ process: AudioProcess) throws {
        let source = MicMixAppSource(process: process)
        try source.start()
        guard let format = source.sourceFormat else {
            source.stop()
            throw CoreAudioError.osStatus(kAudio_ParamError, "could not build mic-mix source format")
        }

        let node = AVAudioSourceNode(format: format) { [ringBuffer = source.ringBuffer] _, _, frameCount, audioBufferList -> OSStatus in
            ringBuffer.read(frameCount: Int(frameCount), into: audioBufferList)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        node.volume = mixVolumes[process.pid] ?? 1.0

        appSources[process.pid] = source
        appSourceNodes[process.pid] = node
    }

    private func removeAppSource(pid: pid_t) {
        if let node = appSourceNodes[pid] {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        }
        appSourceNodes[pid] = nil
        appSources[pid]?.stop()
        appSources[pid] = nil
        missingStreak[pid] = nil
    }
}
