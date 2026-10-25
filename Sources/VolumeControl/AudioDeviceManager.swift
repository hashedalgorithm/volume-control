import AudioToolbox
import CoreAudio
import Foundation

enum CoreAudioError: Error {
    case osStatus(OSStatus, String)
}

struct AudioDevice: Identifiable, Equatable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transportType: UInt32

    /// Best-guess device category icon from name keywords (most specific/reliable
    /// signal CoreAudio gives us for things like "wireless earbuds" vs "soundbar")
    /// falling back to transport type. CoreAudio doesn't expose a formal device
    /// category for output devices -- this is the same practical limit any
    /// third-party volume mixer runs into.
    var iconSymbolName: String {
        let lower = name.lowercased()

        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("beats") { return "beats.headphones" }
        if lower.contains("soundbar") || lower.contains("home theater") || lower.contains("hometheater")
            || lower.contains("theater") || lower.contains("arc") {
            return "tv.and.hifispeaker.fill"
        }
        if lower.contains("earbud") || lower.contains("buds") { return "earbuds" }
        if lower.contains("headphone") || lower.contains("headset") { return "headphones" }

        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv.and.hifispeaker.fill"
        default: return "hifispeaker.fill"
        }
    }
}

enum AudioDeviceManager {
    static func check(_ status: OSStatus, _ context: String) throws {
        guard status == noErr else { throw CoreAudioError.osStatus(status, context) }
    }

    static func outputDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
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

        return ids.compactMap { deviceID in
            guard hasOutputStreams(deviceID) else { return nil }
            let transportType = transportTypeProperty(deviceID)
            guard transportType != kAudioDeviceTransportTypeVirtual, transportType != kAudioDeviceTransportTypeAggregate else {
                return nil
            }
            guard let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(deviceID, selector: kAudioObjectPropertyName) else { return nil }
            return AudioDevice(id: deviceID, uid: uid, name: name, transportType: transportType)
        }
    }

    /// Finds a device by UID with no virtual/output filtering -- needed to locate
    /// VolumeControl's own "Volume Control Mic Mix" virtual device (UID
    /// "com.volumecontrol.micmix"), which outputDevices() deliberately excludes since
    /// it's virtual and isn't a real destination for per-app output routing.
    static func deviceID(forUID uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
            return nil
        }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids) == noErr else {
            return nil
        }
        return ids.first { stringProperty($0, selector: kAudioDevicePropertyDeviceUID) == uid }
    }

    static func defaultInputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : nil
    }

    static func defaultOutputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : nil
    }

    static func defaultOutputDeviceUID() -> String? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        return stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    /// A device's own stored volume -- the same per-device level the volume keys,
    /// Control Center, and System Settings' Sound pane move, and the same level
    /// macOS remembers independently for every output device (confirmed directly:
    /// built-in speakers and a Bluetooth headset held very different stored values on
    /// this machine, 0.49 vs 0.047, which is what made the headset sound quiet even
    /// though nothing in this app's own playback path is device-specific). Uses
    /// `AudioHardwareService...` rather than plain `kAudioDevicePropertyVolumeScalar`
    /// because the service API averages/distributes across however many channels the
    /// device actually has; that's what the system's own volume control uses under
    /// the hood. Returns nil for a device with no settable volume (e.g. some digital
    /// outputs).
    static func volume(for deviceID: AudioObjectID) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioHardwareServiceGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        return status == noErr ? volume : nil
    }

    static func setVolume(_ volume: Float, for deviceID: AudioObjectID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = Float32(volume)
        _ = AudioHardwareServiceSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    static func isMuted(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    static func setMuted(_ muted: Bool, for deviceID: AudioObjectID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = muted ? 1 : 0
        _ = AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    /// Also used to exclude virtual/aggregate devices (e.g. "Microsoft Teams Audio",
    /// Zoom's or our own private tap devices) -- these exist for apps' own internal
    /// routing, aren't real speakers, and picking one as a destination just sends audio
    /// nowhere audible. Real devices (built-in, USB, Bluetooth, HDMI, AirPlay,
    /// Thunderbolt...) all pass through.
    private static func transportTypeProperty(_ deviceID: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType)
        return transportType
    }

    private static func hasOutputStreams(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        return status == noErr && dataSize > 0
    }

    private static func stringProperty(_ deviceID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
