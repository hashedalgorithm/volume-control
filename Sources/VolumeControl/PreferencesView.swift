import AppKit
import ServiceManagement
import SwiftUI

@available(macOS 14.2, *)
struct PreferencesView: View {
    @ObservedObject var model: AudioMixerModel
    @ObservedObject var updateChecker: UpdateChecker

    // Ground truth for "launch at login" lives in launchd/SMAppService, not our own
    // UserDefaults -- same read-through philosophy as Master Volume elsewhere in this
    // app, since the user could also flip this from System Settings > General > Login
    // Items directly.
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    @AppStorage(PreferenceKeys.deviceLevelsExpanded) private var deviceLevelsExpanded = false
    @AppStorage(PreferenceKeys.applicationsExpanded) private var applicationsExpanded = true
    @AppStorage(PreferenceKeys.closeOnOutsideClick) private var closeOnOutsideClick = true
    @AppStorage(PreferenceKeys.autoHideEnabled) private var autoHideEnabled = false
    @AppStorage(PreferenceKeys.autoHideSeconds) private var autoHideSeconds = 10.0

    private var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        ScrollView {
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
                            ErrorLogger.shared.warning("launch-at-login toggle failed: \(error)")
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

                Toggle("Device Levels expanded", isOn: $deviceLevelsExpanded)
                Toggle("Applications expanded", isOn: $applicationsExpanded)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Popup Behavior")
                    .font(.headline)

                Toggle("Close when clicking outside the popup", isOn: $closeOnOutsideClick)
                Toggle("Automatically close after a delay", isOn: $autoHideEnabled)

                if autoHideEnabled {
                    HStack {
                        Slider(value: $autoHideSeconds, in: 5...120, step: 5)
                        Text("\(Int(autoHideSeconds))s")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 32, alignment: .trailing)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Boost")
                    .font(.headline)
                Text("Extra multiplier applied on top of every app's own volume and boost -- 1.00x is no change. Takes effect immediately for whatever's already playing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Slider(
                        value: Binding(get: { model.globalBoostMultiplier }, set: { model.setGlobalBoostMultiplier($0) }),
                        in: AudioMixerModel.globalBoostMultiplierRange,
                        step: 0.25
                    )
                    Text(String(format: "%.2fx", model.globalBoostMultiplier))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Output Priority")
                    .font(.headline)
                Text("When more than one of these is connected, audio automatically routes through whichever is listed highest -- e.g. a Bluetooth speaker over the built-in speakers. If none of them are connected, routing falls back to the system default (normally the Mac's own speakers). An app with its own output device picked in the main panel keeps using that instead, as long as it's still connected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Prioritize specific output devices", isOn: Binding(
                    get: { model.outputPriorityEnabled },
                    set: { model.setOutputPriorityEnabled($0) }
                ))

                if model.outputPriorityEnabled {
                    VStack(spacing: 4) {
                        ForEach(Array(model.outputPriorityOrder.enumerated()), id: \.element.id) { index, entry in
                            HStack(spacing: 6) {
                                Text("\(index + 1).")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(entry.name)
                                    .font(.callout)
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    model.moveOutputPriority(fromOffsets: [index], toOffset: index - 1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(.plain)
                                .disabled(index == 0)
                                Button {
                                    model.moveOutputPriority(fromOffsets: [index], toOffset: index + 2)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(.plain)
                                .disabled(index == model.outputPriorityOrder.count - 1)
                                Button {
                                    model.removeFromOutputPriority(entry)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if availableDevicesToAdd.isEmpty {
                            Text(model.outputPriorityOrder.isEmpty ? "No output devices detected." : "All connected devices are already in the list.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Menu("Add Device\u{2026}") {
                                ForEach(availableDevicesToAdd) { device in
                                    Button(device.name) { model.addToOutputPriority(device) }
                                }
                            }
                            .font(.callout)
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Updates")
                    .font(.headline)
                Text("Downloads just the app binary and HAL plugin driver, not the full installer -- the system-installed virtual mic device itself isn't touched by this, only what's inside the app bundle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                updateSectionContent
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Logs")
                    .font(.headline)
                Text("Critical errors (a stuck audio route, a failed device switch, startup cleanup) are recorded here, in the app's own internal files, to make bugs easier to track down after the fact.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Reveal Log File") {
                        NSWorkspace.shared.activateFileViewerSelecting([ErrorLogger.shared.logFileURL])
                    }
                    Button("Clear Log") {
                        ErrorLogger.shared.clear()
                    }
                }
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
        .frame(width: 340, height: 620)
    }

    private var availableDevicesToAdd: [AudioDevice] {
        model.devices.filter { device in !model.outputPriorityOrder.contains { $0.uid == device.uid } }
    }

    @ViewBuilder
    private var updateSectionContent: some View {
        switch updateChecker.state {
        case .idle:
            Button("Check for Updates") { updateChecker.checkForUpdates() }

        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking\u{2026}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .upToDate:
            HStack {
                Text("You're up to date (v\(updateChecker.currentVersion)).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check Again") { updateChecker.checkForUpdates() }
            }

        case .available(let version):
            VStack(alignment: .leading, spacing: 6) {
                Text("Version \(version) is available (you have \(updateChecker.currentVersion)).")
                    .font(.callout)
                Button("Download & Install") { updateChecker.downloadAndInstall() }
            }

        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                Text("Downloading\u{2026} \(Int(progress * 100))%")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ProgressView(value: progress)
            }

        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Installing\u{2014}Volume Control will quit and relaunch in a moment.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .error(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                Button("Try Again") { updateChecker.checkForUpdates() }
            }
        }
    }
}
