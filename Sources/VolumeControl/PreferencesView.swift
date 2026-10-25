import AppKit
import ServiceManagement
import SwiftUI

@available(macOS 14.2, *)
struct PreferencesView: View {
    // Ground truth for "launch at login" lives in launchd/SMAppService, not our own
    // UserDefaults -- same read-through philosophy as Master Volume elsewhere in this
    // app, since the user could also flip this from System Settings > General > Login
    // Items directly.
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    @AppStorage(PreferenceKeys.systemExpanded) private var systemExpanded = false
    @AppStorage(PreferenceKeys.deviceLevelsExpanded) private var deviceLevelsExpanded = false
    @AppStorage(PreferenceKeys.applicationsExpanded) private var applicationsExpanded = true

    private var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("General")
                    .font(.headline)

                Toggle("Launch Volume Control at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            NSLog("VolumeControl: launch-at-login toggle failed: \(error)")
                            launchAtLogin = SMAppService.mainApp.status == .enabled // reflect actual outcome
                        }
                    }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Default Section State")
                    .font(.headline)
                Text("Whether each section starts expanded or collapsed -- toggling a section in the main panel updates this too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("System expanded", isOn: $systemExpanded)
                Toggle("Device Levels expanded", isOn: $deviceLevelsExpanded)
                Toggle("Applications expanded", isOn: $applicationsExpanded)
            }

            Divider()

            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)

                Text("Volume Control")
                    .font(.system(size: 15, weight: .bold))
                Text(versionString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Developed by hashedalgorithm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(24)
        .frame(width: 340)
    }
}
