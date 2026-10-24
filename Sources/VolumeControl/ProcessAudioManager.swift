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

enum AudioProcessManager {

    static func runningAudioProcesses() -> [AudioProcess] {
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

        let ownPID = ProcessInfo.processInfo.processIdentifier

        return ids.compactMap { processID -> AudioProcess? in
            guard isRunningOutput(processID), let pid = pidProperty(processID), let bundleID = bundleIDProperty(processID) else {
                return nil
            }
            // VolumeControl's own playback (re-rendering captured app audio) makes it
            // show up here too; it's the master output path, not "another app" to track.
            guard pid != ownPID else { return nil }
            return AudioProcess(id: processID, pid: pid, bundleID: bundleID)
        }
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
/// app's direct hardware output, and re-renders the captured samples back through the
/// system's current default output at a user-controlled volume -- i.e. a per-app volume
/// knob, with no change to where the audio plays.
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
    private var ioProcID: AudioDeviceIOProcID?
    private let engine = AVAudioEngine()
    private let ringBuffer = AudioRingBuffer(capacityFrames: 1 << 16)

    var volume: Float = 1.0 {
        didSet { engine.mainMixerNode.outputVolume = volume }
    }

    init(process: AudioProcess) {
        self.process = process
    }

    func start() throws {
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

        try startEngine()
        try startIOProc()
    }

    func stop() {
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

    deinit { stop() }

    // MARK: - Playback side (AVAudioEngine -> system default output)

    /// The tap's *actual* operating sample rate, read back from the aggregate device
    /// rather than assumed. The CoreAudio HAL's canonical format is always Float32,
    /// non-interleaved; a stereo-mixdown tap is always 2 channels -- only the sample
    /// rate needs to be discovered. Playing back samples tagged with the wrong sample
    /// rate is what produced the distorted/unclear audio in the first pass of this
    /// feature: the source node was told it held samples in the *output hardware's*
    /// format while the ring buffer actually held samples in the *tap's* format.
    private func tapSampleRate() -> Float64 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 48000
        var size = UInt32(MemoryLayout<Float64>.size)
        _ = AudioObjectGetPropertyData(aggregateDeviceID, &address, 0, nil, &size, &rate)
        return rate
    }

    private func startEngine() throws {
        guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: tapSampleRate(),
                                                channels: 2, interleaved: false) else {
            throw CoreAudioError.osStatus(kAudio_ParamError, "could not build source format")
        }

        let sourceNode = AVAudioSourceNode(format: sourceFormat) { [ringBuffer] _, _, frameCount, audioBufferList -> OSStatus in
            ringBuffer.read(frameCount: Int(frameCount), into: audioBufferList)
            return noErr
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: sourceFormat)
        engine.mainMixerNode.outputVolume = volume
        try engine.start()
    }

    // MARK: - Capture side (tap aggregate IOProc -> ring buffer)

    private func startIOProc() throws {
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, nil) { [weak self] _, inInputData, _, _, _ in
            guard let self else { return }
            self.ringBuffer.write(from: inInputData)
        }
        try AudioDeviceManager.check(status, "create tap IOProc")
        ioProcID = procID
        try AudioDeviceManager.check(AudioDeviceStart(aggregateDeviceID, procID), "start tap IOProc")
    }
}
