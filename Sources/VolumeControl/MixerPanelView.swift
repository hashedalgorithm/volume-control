import SwiftUI

/// Mirrors macOS's own volume icon convention: muted gets a distinct slashed icon,
/// and unmuted reflects how loud the level actually is (silent/quiet/medium/loud)
/// rather than a flat two-state toggle.
func speakerIconName(isMuted: Bool, volume: Float) -> String {
    if isMuted { return "speaker.slash.fill" }
    switch volume {
    case ..<0.001: return "speaker.fill"
    case ..<0.34: return "speaker.wave.1.fill"
    case ..<0.67: return "speaker.wave.2.fill"
    default: return "speaker.wave.3.fill"
    }
}

private enum MixerTab: String, CaseIterable {
    case output = "Output"
    case input = "Input"
}

/// Two-segment switch next to the tab bar: Single on the left, Multiple on the right,
/// with a sliding highlight showing the actual current state (derived, not a free
/// choice). Tapping Single consolidates every app onto one device; tapping Multiple
/// does nothing by design -- there's no real "force them apart" action, only
/// "consolidate to one" -- so the highlight will just snap back to wherever reality
/// actually is on the next refresh if it doesn't match what was tapped.
@available(macOS 14.2, *)
private struct DeviceModeSwitchView: View {
    let mode: DeviceRoutingMode
    let onConsolidate: () -> Void

    private let segmentWidth: CGFloat = 46
    private let segmentHeight: CGFloat = 18

    var body: some View {
        HStack(spacing: 0) {
            segment(.single, title: "Single")
            segment(.multiple, title: "Multiple")
        }
        .padding(2)
        .background(Capsule().fill(.secondary.opacity(0.12)))
        .animation(.easeInOut(duration: 0.2), value: mode)
    }

    private func segment(_ segmentMode: DeviceRoutingMode, title: String) -> some View {
        Button {
            if segmentMode == .single { onConsolidate() }
        } label: {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .frame(width: segmentWidth, height: segmentHeight)
                .foregroundStyle(mode == segmentMode ? Color.white : Color.secondary)
                .background(mode == segmentMode ? Capsule().fill(Color.accentColor) : nil)
        }
        .buttonStyle(.plain)
    }
}

@available(macOS 14.2, *)
struct MixerPanelView: View {
    @ObservedObject var model: AudioMixerModel
    @ObservedObject var inputModel: InputMixEngine
    var onQuit: () -> Void
    var onClose: () -> Void

    @State private var selectedTab: MixerTab = .output

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Volume Control")
                    .font(.system(size: 15, weight: .bold))

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding([.top, .horizontal], 14)
            .padding(.bottom, 10)

            HStack {
                Picker("", selection: $selectedTab) {
                    ForEach(MixerTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer()

                if selectedTab == .output, !model.deviceLevels.isEmpty {
                    DeviceModeSwitchView(mode: model.deviceMode, onConsolidate: { model.consolidateToSingleDevice() })
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Divider()

            switch selectedTab {
            case .output:
                OutputTabView(model: model)
            case .input:
                InputTabView(model: inputModel)
            }

            Divider()

            Button("Quit Volume Control", action: onQuit)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.callout)
                .padding(12)
        }
        .frame(width: 340)
        // NSPopover used to supply this chrome automatically; a plain NSWindow-hosted
        // panel (needed for full control over positioning -- see PopoverController)
        // needs it drawn explicitly.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Shared collapsible-section chrome used by System, Device Levels, and Applications
/// so all three expand/collapse the same way: the whole header row (title, chevron) is
/// tappable -- not just the chevron, which is what SwiftUI's built-in DisclosureGroup
/// restricts the hit area to on macOS -- and identical padding whether expanded or
/// collapsed so there's no dead/uneven gap before the next Divider.
///
/// A GeometryReader-measured .frame(height:) approach was tried here to get a pure
/// height/clip reveal like native macOS disclosure (no fade) but the measured height
/// never reliably fed back through the frame constraint -- content stayed collapsed
/// regardless of state. Reverted to conditional insertion with an opacity-only
/// transition (no .move, which was the actual source of the original "sliding and
/// popping" complaint) under withAnimation, which lets SwiftUI animate the surrounding
/// layout reflow smoothly together with the fade.
@available(macOS 14.2, *)
private struct CollapsibleSection<Content: View>: View {
    let title: String
    var trailingLabel: String?
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let trailingLabel {
                        Text(trailingLabel)
                            .font(.system(size: 11, weight: .regular).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if isExpanded {
                content()
                    .padding(.bottom, 10)
                    // Fade + a slight grow-from-top rather than a flat opacity pop --
                    // closer to how native macOS content reveals (popovers, menus)
                    // ease into place instead of snapping to full size immediately.
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
    }
}

@available(macOS 14.2, *)
private struct OutputTabView: View {
    @ObservedObject var model: AudioMixerModel
    @State private var isSystemExpanded = true
    @State private var isDeviceLevelsExpanded = false
    @State private var isApplicationsExpanded = true

    /// Beyond this many app rows, the list scrolls with a fixed, screen-safe height
    /// instead of growing the popover further -- a forced `minHeight` here previously
    /// pushed the whole popover tall enough that AppKit repositioned it off the top of
    /// the screen with no way to reach the controls to close it.
    private static let maxRowsBeforeScroll = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CollapsibleSection(title: "SYSTEM", trailingLabel: "\(Int(model.masterVolume * 100))%", isExpanded: $isSystemExpanded) {
                VStack(spacing: 2) {
                    MasterVolumeRowView(volume: model.masterVolume, isMuted: model.isMasterMuted,
                                         onVolumeChange: { model.setMasterVolume($0) },
                                         onToggleMute: { model.toggleMasterMute() })

                    if let systemRow = model.systemSoundsRow {
                        AppRowView(row: systemRow, devices: model.devices,
                                   isDeviceSwitchPending: model.pendingDeviceSwitchPIDs.contains(systemRow.id),
                                   onVolumeChange: { model.setVolume($0, for: systemRow) },
                                   onToggleMute: { model.toggleMute(for: systemRow) },
                                   onDeviceChange: { model.setOutputDevice($0, for: systemRow) })
                    }
                }
            }

            Divider()

            if !model.deviceLevels.isEmpty {
                CollapsibleSection(title: "DEVICE LEVELS", trailingLabel: model.deviceMode.rawValue, isExpanded: $isDeviceLevelsExpanded) {
                    VStack(spacing: 2) {
                        ForEach(model.deviceLevels) { row in
                            DeviceLevelRowView(row: row,
                                                onVolumeChange: { model.setDeviceVolume($0, for: row) },
                                                onToggleMute: { model.toggleDeviceMute(for: row) })
                        }
                    }
                }

                Divider()
            }

            CollapsibleSection(title: "APPLICATIONS", trailingLabel: "\(model.apps.count)", isExpanded: $isApplicationsExpanded) {
                if model.apps.isEmpty {
                    Text("No apps currently playing audio")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .padding(.horizontal, 14)
                } else if model.apps.count <= Self.maxRowsBeforeScroll {
                    // Plain VStack, no ScrollView: lets SwiftUI size the popover to
                    // its true natural height with no ambiguity, which is what
                    // actually guarantees no scrollbar up to this many rows.
                    VStack(spacing: 2) {
                        ForEach(model.apps) { row in
                            AppRowView(row: row, devices: model.devices,
                                       isDeviceSwitchPending: model.pendingDeviceSwitchPIDs.contains(row.id),
                                       onVolumeChange: { model.setVolume($0, for: row) },
                                       onToggleMute: { model.toggleMute(for: row) },
                                       onDeviceChange: { model.setOutputDevice($0, for: row) })
                        }
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(model.apps) { row in
                                AppRowView(row: row, devices: model.devices,
                                           isDeviceSwitchPending: model.pendingDeviceSwitchPIDs.contains(row.id),
                                           onVolumeChange: { model.setVolume($0, for: row) },
                                           onToggleMute: { model.toggleMute(for: row) },
                                           onDeviceChange: { model.setOutputDevice($0, for: row) })
                            }
                        }
                    }
                    .frame(height: 260) // fixed, screen-safe; longer lists scroll within this
                }
            }
        }
    }
}

@available(macOS 14.2, *)
private struct DeviceLevelRowView: View {
    let row: DeviceLevelRow
    let onVolumeChange: (Float) -> Void
    let onToggleMute: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.iconSymbolName)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .opacity(row.isMuted ? 0.5 : 1.0)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .opacity(row.isMuted ? 0.5 : 1.0)

                    Spacer()

                    Button(action: onToggleMute) {
                        Image(systemName: speakerIconName(isMuted: row.isMuted, volume: row.volume))
                            .font(.system(size: 11))
                            .foregroundStyle(row.isMuted ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(row.isMuted ? "Unmute" : "Mute")

                    Text("\(Int(row.volume * 100))%")
                        .font(.system(size: 11, weight: .regular).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                        .opacity(row.isMuted ? 0.5 : 1.0)
                }

                Slider(value: Binding(get: { row.volume }, set: onVolumeChange), in: 0...1)
                    .opacity(row.isMuted ? 0.5 : 1.0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

@available(macOS 14.2, *)
private struct MasterVolumeRowView: View {
    let volume: Float
    let isMuted: Bool
    let onVolumeChange: (Float) -> Void
    let onToggleMute: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Distinct from the mute button's speaker glyph below -- a mixer/fader
            // icon reads as "master control" rather than duplicating a speaker icon.
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .opacity(isMuted ? 0.5 : 1.0)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Master Volume")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .opacity(isMuted ? 0.5 : 1.0)

                    Spacer()

                    Button(action: onToggleMute) {
                        Image(systemName: speakerIconName(isMuted: isMuted, volume: volume))
                            .font(.system(size: 11))
                            .foregroundStyle(isMuted ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isMuted ? "Unmute" : "Mute")

                    Text("\(Int(volume * 100))%")
                        .font(.system(size: 11, weight: .regular).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                        .opacity(isMuted ? 0.5 : 1.0)
                }

                Slider(value: Binding(get: { volume }, set: onVolumeChange), in: 0...1)
                    .opacity(isMuted ? 0.5 : 1.0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

@available(macOS 14.2, *)
private struct AppRowView: View {
    let row: AppRow
    let devices: [AudioDevice]
    var isDeviceSwitchPending: Bool = false
    let onVolumeChange: (Float) -> Void
    let onToggleMute: () -> Void
    let onDeviceChange: (AudioDevice) -> Void

    private var selectedDeviceName: String {
        devices.first(where: { $0.uid == row.outputDeviceUID })?.name ?? "Default"
    }

    private var selectedDeviceIcon: String {
        devices.first(where: { $0.uid == row.outputDeviceUID })?.iconSymbolName ?? "hifispeaker.fill"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let symbolName = row.leadingSystemSymbolName {
                    // Pinned system row (e.g. "System Sounds"): smaller, same
                    // secondary gray as Master Volume's icon, not a full-size
                    // full-color app icon.
                    Image(systemName: symbolName)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else if let icon = row.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(width: 26, height: 26)
            .opacity(row.isMuted ? 0.5 : 1.0)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .opacity(row.isMuted ? 0.5 : 1.0)

                    Spacer()

                    Button(action: onToggleMute) {
                        Image(systemName: speakerIconName(isMuted: row.isMuted, volume: row.volume))
                            .font(.system(size: 11))
                            .foregroundStyle(row.isMuted ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(row.isMuted ? "Unmute" : "Mute")

                    Text("\(Int(row.volume * 100))%")
                        .font(.system(size: 11, weight: .regular).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                        .opacity(row.isMuted ? 0.5 : 1.0)
                }

                HStack(spacing: 6) {
                    Slider(value: Binding(get: { row.volume }, set: onVolumeChange), in: 0...1)
                        .opacity(row.isMuted ? 0.5 : 1.0)

                    // A ProgressView placed inside a Menu's label gets bridged to a
                    // static AppKit snapshot rather than staying a live animating
                    // view, so it never visibly spun there. Swapping out the whole
                    // Menu for a plain view while pending keeps it a real, live
                    // SwiftUI view that actually animates.
                    if isDeviceSwitchPending {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 16, height: 16)
                            .help("Switching output device\u{2026}")
                    } else {
                        Menu {
                            ForEach(devices) { device in
                                Button {
                                    onDeviceChange(device)
                                } label: {
                                    HStack {
                                        Image(systemName: device.iconSymbolName)
                                        Text(device.name)
                                        if device.uid == row.outputDeviceUID {
                                            Spacer()
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: selectedDeviceIcon)
                                .font(.system(size: 10))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Output: \(selectedDeviceName)")
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}
