import AVFoundation
import CoreAudio
import Foundation

/// A running app that is producing (or has produced) audio output, discovered via
/// CoreAudio's public process-object API (`kAudioHardwarePropertyProcessObjectList`,
/// macOS 14.0+).
struct AudioProcess: Identifiable, Equatable {
    let id: AudioObjectID
    let pid: pid_t
    let bundleID: String
    var displayName: String {
        Bundle(identifier: bundleID)?.infoDictionary?["CFBundleName"] as? String ?? bundleID
    }
}

/// `systemsoundserverd`'s bundle identifier, as queried via
/// `kAudioProcessPropertyBundleID` -- it's the daemon behind alert/notification/UI
/// sounds. It spins up output only for the instant it plays a sound, which is why it
/// used to flicker in and out of the per-app list; it's tracked separately instead and
/// pinned as an always-present "System Sounds" row.
private let systemSoundsBundleID = "systemsoundserverd"

enum AudioProcessManager {

    static func runningAudioProcesses() -> [AudioProcess] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return allProcessObjects().compactMap { processID -> AudioProcess? in
            guard isRunningOutput(processID), let pid = pidProperty(processID), let bundleID = bundleIDProperty(processID) else {
                return nil
            }
            // VolumeControl's own playback (re-rendering captured app audio) makes it
            // show up here too; it's the master output path, not "another app" to track.
            guard pid != ownPID, bundleID != systemSoundsBundleID else { return nil }
            return AudioProcess(id: processID, pid: pid, bundleID: bundleID)
        }
    }

    /// Unlike `runningAudioProcesses()`, this doesn't require the process to be
    /// outputting audio *right now* -- the system sounds row needs to stay pinned and
    /// controllable even between alert sounds.
    static func systemSoundsProcess() -> AudioProcess? {
        for processID in allProcessObjects() {
            guard let pid = pidProperty(processID), let bundleID = bundleIDProperty(processID),
                  bundleID == systemSoundsBundleID else { continue }
            return AudioProcess(id: processID, pid: pid, bundleID: bundleID)
        }
        return nil
    }

    private static func allProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func isRunningOutput(_ processID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(processID, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    private static func pidProperty(_ processID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(processID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func bundleIDProperty(_ processID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(processID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}

/// Captures one app's audio via a private `CATapDescription` process tap, mutes the
/// app's direct hardware output, and re-renders the captured samples at a user-
/// controlled volume through a user-chosen output device (the system default if none
/// is chosen) -- a per-app volume knob plus per-app output routing.
///
/// This mirrors the public per-process tap mechanism Apple ships in CoreAudio
/// (`AudioHardwareCreateProcessTap`, macOS 14.2+) rather than any vendor-specific
/// driver, so it needs no kernel extension or virtual audio device of its own.
@available(macOS 14.2, *)
final class ProcessAudioRoute {
    let process: AudioProcess

    private var tapID: AudioObjectID = 0
    private var tapUUID: String = ""
    private var aggregateDeviceID: AudioObjectID = 0
    private var captureStreamID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    /// Rebuilt from scratch (not reused in place) every time startEngine() runs after
    /// the first call -- see startEngine() for why.
    private var engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let ringBuffer = AudioRingBuffer(capacityFrames: 1 << 16)
    private var captureFormat = AudioStreamBasicDescription()
    private var currentOutputDeviceUID: String?
    private var formatListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    var volume: Float = 1.0 {
        didSet { applyGain() }
    }

    // MARK: - Boost
    //
    // Core Audio's process tap applies its own internal loudness-compensation when it
    // mixes a tapped process's streams down to stereo (see CATapDescription's
    // initStereoMixdownOfProcesses) -- not something exposed as a property we can turn
    // off. Measured directly (coreaudiod's own RTAID RMS/peak logging, same audio
    // compared with VolumeControl routing it vs. quit and playing natively): routed
    // peaks sat around -18 to -39 dBFS where native reached -5.6 dBFS, a real ~15-20dB
    // loss specific to the tap path. Boost is makeup gain applied after capture, before
    // replay, to compensate -- a second multiplier on top of the normal volume slider.
    private var boostMode: BoostMode = .off
    private var boostPercent: Double = BoostPreset.low.rawValue
    /// Auto mode's own continuously-recomputed compensation; unused by the other modes.
    private var autoMultiplier: Float = 1.0
    private let peakLock = NSLock()
    /// Highest sample magnitude seen since the last auto-gain tick; reset to 0 each tick.
    private var measuredPeak: Float = 0
    private var autoGainTimer: Timer?

    private static let autoTickInterval: TimeInterval = 0.15
    private static let autoTargetPeak: Float = 0.5 // -6 dBFS ceiling, headroom against clipping
    private static let autoMaxMultiplier: Float = 2.0 // matches custom boost's 100% ceiling
    /// Gain moves toward a lower multiplier (signal got louder, pull back) fast, and
    /// toward a higher one (signal got quieter, boost more) slowly -- same asymmetric
    /// ballistics as a compressor's attack/release, so a brief loud transient doesn't
    /// get undone instantly but also doesn't clip, while quiet stretches ease up to the
    /// target rather than pumping.
    private static let autoAttack: Float = 0.6
    private static let autoRelease: Float = 0.05

    init(process: AudioProcess) {
        self.process = process
    }

    /// `percent` is ignored (but still stored) for `.off`/`.auto`.
    func setBoost(mode: BoostMode, percent: Double) {
        boostMode = mode
        boostPercent = percent
        if mode == .auto {
            startAutoGain()
        } else {
            stopAutoGain()
            autoMultiplier = 1.0 // clean restart if auto is re-enabled later
        }
        applyGain()
    }

    private func applyGain() {
        let boost: Float
        switch boostMode {
        case .off: boost = 1.0
        case .auto: boost = autoMultiplier
        case .preset, .custom: boost = 1.0 + Float(boostPercent / 100.0)
        }
        engine.mainMixerNode.outputVolume = volume * boost
    }

    private func startAutoGain() {
        guard autoGainTimer == nil else { return }
        peakLock.lock(); measuredPeak = 0; peakLock.unlock()
        autoGainTimer = Timer.scheduledTimer(withTimeInterval: Self.autoTickInterval, repeats: true) { [weak self] _ in
            self?.tickAutoGain()
        }
    }

    private func stopAutoGain() {
        autoGainTimer?.invalidate()
        autoGainTimer = nil
    }

    private func tickAutoGain() {
        peakLock.lock()
        let peak = measuredPeak
        measuredPeak = 0
        peakLock.unlock()

        guard peak > 0.001 else { return } // near-silence; hold the last multiplier rather than spiking it
        let desired = min(Self.autoMaxMultiplier, max(1.0, Self.autoTargetPeak / peak))
        let coefficient: Float = desired < autoMultiplier ? Self.autoAttack : Self.autoRelease
        autoMultiplier += (desired - autoMultiplier) * coefficient
        applyGain()
    }

    /// Called from the capture IOProc thread (only while boostMode == .auto) with this
    /// callback's peak sample magnitude; accumulates the loudest one seen since the
    /// last auto-gain tick. Matches this file's existing convention of taking a plain
    /// NSLock from inside the IOProc callback (see AudioRingBuffer, used the same way
    /// a few lines below this).
    private func recordPeak(_ peak: Float) {
        guard peak > 0 else { return }
        peakLock.lock()
        if peak > measuredPeak { measuredPeak = peak }
        peakLock.unlock()
    }

    private static func peak(in data: UnsafePointer<Float>, count: Int) -> Float {
        var result: Float = 0
        for i in 0..<count {
            let magnitude = abs(data[i])
            if magnitude > result { result = magnitude }
        }
        return result
    }

    private static func peak(inNonInterleaved bufferList: UnsafePointer<AudioBufferList>) -> Float {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        var result: Float = 0
        for buffer in abl {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let magnitude = peak(in: data, count: count)
            if magnitude > result { result = magnitude }
        }
        return result
    }

    func start(outputDeviceUID: String? = nil) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: [process.id])
        description.name = "VolumeControl-tap-\(process.pid)"
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.muted

        var newTapID: AudioObjectID = 0
        try AudioDeviceManager.check(AudioHardwareCreateProcessTap(description, &newTapID), "create process tap")
        tapID = newTapID
        tapUUID = description.uuid.uuidString

        let dict: [String: Any] = [
            kAudioAggregateDeviceUIDKey: "com.volumecontrol.tap.\(process.pid).\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUUID, kAudioSubTapDriftCompensationKey: true]
            ]
        ]

        var newAggregateID: AudioObjectID = 0
        try AudioDeviceManager.check(
            AudioHardwareCreateAggregateDevice(dict as CFDictionary, &newAggregateID),
            "create tap aggregate device"
        )
        aggregateDeviceID = newAggregateID
        (captureFormat, captureStreamID) = try queryCaptureFormat()
        currentOutputDeviceUID = outputDeviceUID

        try startEngine(outputDeviceUID: outputDeviceUID)
        try startIOProc()
        startWatchingForFormatChanges()
        startWatchingForDefaultDeviceChanges()
    }

    /// Switches which physical output device the re-rendered audio plays through,
    /// without touching the capture side (tap keeps running, no audio gap on the
    /// source app's side -- only this route's own playback engine restarts briefly).
    func setOutputDevice(uid: String?) throws {
        currentOutputDeviceUID = uid
        try startEngine(outputDeviceUID: uid)
    }

    func stop() {
        stopWatchingForFormatChanges()
        stopWatchingForDefaultDeviceChanges()
        stopAutoGain()
        engine.stop()
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

    // MARK: - Reacting to the capture format changing at runtime
    //
    // The tap mirrors whatever rate the system's audio is currently running at. If the
    // user switches to an output device with a different native sample rate *while* a
    // route is live, the old fixed-at-start-time format would go stale: the ring
    // buffer's producer (IOProc) and consumer (AVAudioSourceNode) would silently
    // disagree, which is exactly the slowed/distorted/panned class of bug fixed
    // earlier, just re-triggered by a device change instead of a wrong initial guess.
    // Watching the stream's own format property and reconfiguring on change keeps it
    // correct for the life of the route, not just at creation.

    private func startWatchingForFormatChanges() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleCaptureFormatChanged()
        }
        formatListenerBlock = block
        AudioObjectAddPropertyListenerBlock(captureStreamID, &address, DispatchQueue.main, block)
    }

    private func stopWatchingForFormatChanges() {
        guard let block = formatListenerBlock, captureStreamID != 0 else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(captureStreamID, &address, DispatchQueue.main, block)
        formatListenerBlock = nil
    }

    private func handleCaptureFormatChanged() {
        guard let (newFormat, _) = try? queryCaptureFormat() else { return }
        let formatUnchanged = newFormat.mSampleRate == captureFormat.mSampleRate
            && newFormat.mChannelsPerFrame == captureFormat.mChannelsPerFrame
            && newFormat.mFormatFlags == captureFormat.mFormatFlags
        guard !formatUnchanged else { return }

        captureFormat = newFormat
        // The IOProc reads captureFormat's channel count/interleaved flag fresh on
        // every callback (see startIOProc), so only the playback side -- which bakes
        // the format into a fixed AVAudioFormat -- needs rebuilding.
        try? startEngine(outputDeviceUID: currentOutputDeviceUID)
    }

    // MARK: - Reacting to the system default output device changing at runtime
    //
    // A route with no explicit per-app output override (the default for every app
    // until the user picks one) relies on AVAudioEngine's own implicit default-output
    // binding. That binding does not reliably survive the user switching the system's
    // default output device live (System Settings, Control Center, the menu bar) --
    // the underlying AUHAL can go stale and stop producing sound until the engine is
    // torn down and restarted. This previously only got fixed by accident when a
    // device switch happened to also change the sample rate, which re-triggered the
    // format-change handler above. Watching the default-device property directly
    // means it recovers on every switch, not just ones that also change the rate.

    private func startWatchingForDefaultDeviceChanges() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultOutputDeviceChanged()
        }
        defaultDeviceListenerBlock = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }

    private func stopWatchingForDefaultDeviceChanges() {
        guard let block = defaultDeviceListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        defaultDeviceListenerBlock = nil
    }

    private func handleDefaultOutputDeviceChanged() {
        // Only routes following the system default need rebinding; an explicit
        // per-app override keeps pointing at the device the user picked regardless of
        // what the system default is doing.
        guard currentOutputDeviceUID == nil else { return }
        try? startEngine(outputDeviceUID: nil)
    }

    deinit { stop() }

    /// The tap's *actual* operating format, read straight from the aggregate device's
    /// own input stream rather than assumed. Guessing wrong here is what produced the
    /// earlier distorted/unclear audio (wrong sample rate) and the hard-right-panned,
    /// slowed-down audio after that (assumed non-interleaved when the stream was
    /// actually interleaved, so one buffer's L/R-alternating samples got read as twice
    /// as many mono frames and only ever landed in channel 0).
    private func queryCaptureFormat() throws -> (AudioStreamBasicDescription, AudioObjectID) {
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
        return (format, streamID)
    }

    // MARK: - Playback side (AVAudioEngine -> chosen output device, default system output if nil)

    private func startEngine(outputDeviceUID: String?) throws {
        // A fresh AVAudioEngine instance every time, rather than reusing the same one
        // across stop()/reconfigure/start() cycles: reusing it was the actual bug
        // behind "picked a per-app output device, no audio, picked it again (or
        // anything else that re-ran this), audio came back." AVAudioEngine's output
        // unit doesn't reliably re-bind to a new device when
        // kAudioOutputUnitProperty_CurrentDevice is changed on an already-initialized,
        // already-started output unit -- it can silently keep rendering into the old
        // device's now-stale connection until something forces a full reset. A brand
        // new engine has no such state to go stale.
        engine.stop()
        engine = AVAudioEngine()
        sourceNode = nil

        if let outputDeviceUID {
            guard let device = AudioDeviceManager.outputDevices().first(where: { $0.uid == outputDeviceUID }) else {
                throw CoreAudioError.osStatus(kAudio_ParamError, "unknown output device uid")
            }
            guard let outputAudioUnit = engine.outputNode.audioUnit else {
                throw CoreAudioError.osStatus(kAudio_ParamError, "engine has no output audio unit")
            }
            // kAudioOutputUnitProperty_CurrentDevice is only settable while the unit is
            // uninitialized (Apple's documented contract for this property); merely
            // touching .audioUnit on a fresh engine can already have lazily
            // initialized it, so the set below could silently not fully take effect
            // without this -- the likely cause of needing multiple attempts before a
            // picked device actually produced audio.
            AudioUnitUninitialize(outputAudioUnit)
            var deviceID = device.id
            try AudioDeviceManager.check(
                AudioUnitSetProperty(outputAudioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                      &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)),
                "bind engine output to device"
            )
        }

        guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: captureFormat.mSampleRate,
                                                channels: AVAudioChannelCount(captureFormat.mChannelsPerFrame),
                                                interleaved: false) else {
            throw CoreAudioError.osStatus(kAudio_ParamError, "could not build source format")
        }

        let newSourceNode = AVAudioSourceNode(format: sourceFormat) { [ringBuffer] _, _, frameCount, audioBufferList -> OSStatus in
            ringBuffer.read(frameCount: Int(frameCount), into: audioBufferList)
            return noErr
        }
        engine.attach(newSourceNode)
        engine.connect(newSourceNode, to: engine.mainMixerNode, format: sourceFormat)
        applyGain()
        sourceNode = newSourceNode
        try engine.start()
    }

    // MARK: - Capture side (tap aggregate IOProc -> ring buffer)

    private func startIOProc() throws {
        var procID: AudioDeviceIOProcID?
        // Reads self.captureFormat fresh on every callback (rather than closing over
        // fixed values) so a runtime format change -- picked up by the property
        // listener and written to captureFormat on the main queue -- takes effect
        // here without needing to tear down and recreate the IOProc itself.
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, nil) { [weak self] _, inInputData, _, _, _ in
            guard let self else { return }
            let format = self.captureFormat
            let isInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
            let channelCount = Int(format.mChannelsPerFrame)
            if isInterleaved {
                let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
                guard let buffer = abl.first, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
                let frameCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / max(channelCount, 1)
                if self.boostMode == .auto { self.recordPeak(Self.peak(in: data, count: frameCount * channelCount)) }
                self.ringBuffer.writeInterleaved(data, frameCount: frameCount, channelCount: channelCount)
            } else {
                if self.boostMode == .auto { self.recordPeak(Self.peak(inNonInterleaved: inInputData)) }
                self.ringBuffer.write(from: inInputData)
            }
        }
        try AudioDeviceManager.check(status, "create tap IOProc")
        ioProcID = procID
        try AudioDeviceManager.check(AudioDeviceStart(aggregateDeviceID, procID), "start tap IOProc")
    }
}
