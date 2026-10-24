import Foundation

/// Installs the HAL plugin bundled inside this app (see HALPlugin/, copied into
/// Contents/Resources by Scripts/make_app_bundle.sh) into
/// /Library/Audio/Plug-Ins/HAL. Uses a single native macOS admin-password prompt
/// (AppleScript's `do shell script ... with administrator privileges`) rather than
/// running anything privileged silently -- the standard, user-visible way an app
/// installs a system component.
enum MicMixInstaller {
    static let deviceUID = "com.volumecontrol.micmix"

    static func isInstalled() -> Bool {
        AudioDeviceManager.deviceID(forUID: deviceUID) != nil
    }

    enum InstallError: Error, LocalizedError {
        case bundleMissing
        case scriptFailed(String)
        case canceled

        var errorDescription: String? {
            switch self {
            case .bundleMissing: return "VolumeControlMicMix.driver wasn't found inside this app -- rebuild with Scripts/make_app_bundle.sh."
            case .scriptFailed(let message): return message
            case .canceled: return "Install canceled."
            }
        }
    }

    /// Blocks the calling thread until the password prompt is dismissed -- callers
    /// must run this off the main thread.
    static func install() throws {
        guard let resourceURL = Bundle.main.resourceURL else { throw InstallError.bundleMissing }
        let driverURL = resourceURL.appendingPathComponent("VolumeControlMicMix.driver")
        guard FileManager.default.fileExists(atPath: driverURL.path) else { throw InstallError.bundleMissing }

        let destDir = "/Library/Audio/Plug-Ins/HAL"
        let shell = "mkdir -p '\(destDir)' && rm -rf '\(destDir)/VolumeControlMicMix.driver' "
            + "&& cp -R '\(driverURL.path)' '\(destDir)/' "
            + "&& chown -R root:wheel '\(destDir)/VolumeControlMicMix.driver' "
            + "&& killall coreaudiod"
        let escapedShell = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escapedShell)\" with administrator privileges"

        guard let script = NSAppleScript(source: appleScript) else {
            throw InstallError.scriptFailed("Could not build the install script.")
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            if number == -128 { throw InstallError.canceled } // user dismissed the password prompt
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown error."
            throw InstallError.scriptFailed(message)
        }
    }
}
