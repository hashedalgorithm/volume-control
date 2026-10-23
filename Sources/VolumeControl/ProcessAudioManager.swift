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

        return ids.compactMap { processID -> AudioProcess? in
            guard isRunningOutput(processID), let pid = pidProperty(processID), let bundleID = bundleIDProperty(processID) else {
                return nil
            }
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
/// app's direct hardware output for the duration of the capture, and re-renders the
/// captured samples through a user-chosen output device at a user-chosen volume.
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
    private var sourceFormat: AVAudioFormat?
    private let ringBuffer = AudioRingBuffer(capacityFrames: 1 << 16)

    var volume: Float = 1.0 {
        didSet { engine.mainMixerNode.outputVolume = volume }
    }

    init(process: AudioProcess) {
        self.process = process
    }

    func start(outputDeviceUID: String) throws {
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

        try startEngine(outputDeviceUID: outputDeviceUID)
        try startIOProc()
    }

    func updateOutputDevice(outputDeviceUID: String) throws {
        engine.stop()
        try startEngine(outputDeviceUID: outputDeviceUID)
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

    // MARK: - Playback side (AVAudioEngine -> chosen output device)

    private func startEngine(outputDeviceUID: String) throws {
        guard let outputAudioUnit = engine.outputNode.audioUnit else {
            throw CoreAudioError.osStatus(kAudio_ParamError, "engine has no output audio unit")
        }
        guard let deviceID = try AudioDeviceManager.outputDevices().first(where: { $0.uid == outputDeviceUID })?.id else {
            throw CoreAudioError.osStatus(kAudio_ParamError, "unknown output device uid")
        }
        var mutableDeviceID = deviceID
        try AudioDeviceManager.check(
            AudioUnitSetProperty(outputAudioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                  &mutableDeviceID, UInt32(MemoryLayout<AudioDeviceID>.size)),
            "bind engine output to device"
        )

        let format = engine.outputNode.inputFormat(forBus: 0)
        let sourceNode = AVAudioSourceNode(format: format) { [ringBuffer] _, _, frameCount, audioBufferList -> OSStatus in
            ringBuffer.read(frameCount: Int(frameCount), into: audioBufferList)
            return noErr
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = volume
        try engine.start()
    }

    // MARK: - Capture side (tap aggregate IOProc -> ring buffer)

    private func startIOProc() throws {
        var procID: AudioDeviceIOProcID?
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, nil) { [weak self] _, inInputData, _, _, _ in
            guard let self else { return }
            self.ringBuffer.write(from: inInputData)
        }
        _ = selfPtr
        try AudioDeviceManager.check(status, "create tap IOProc")
        ioProcID = procID
        try AudioDeviceManager.check(AudioDeviceStart(aggregateDeviceID, procID), "start tap IOProc")
    }
}
