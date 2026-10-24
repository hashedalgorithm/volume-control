import CoreAudio
import Foundation

enum CoreAudioError: Error {
    case osStatus(OSStatus, String)
}

enum AudioDeviceManager {
    static func check(_ status: OSStatus, _ context: String) throws {
        guard status == noErr else { throw CoreAudioError.osStatus(status, context) }
    }
}
