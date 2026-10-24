import SwiftUI

/// Mirrors macOS's own volume icon convention: muted gets a distinct slashed icon,
/// and unmuted reflects how loud the level actually is (silent/quiet/medium/loud)
/// rather than a flat two-state toggle.
private func speakerIconName(isMuted: Bool, volume: Float) -> String {
    if isMuted { return "speaker.slash.fill" }
    switch volume {
    case ..<0.001: return "speaker.fill"
    case ..<0.34: return "speaker.wave.1.fill"
    case ..<0.67: return "speaker.wave.2.fill"
    default: return "speaker.wave.3.fill"
    }
}

@available(macOS 14.2, *)
struct MixerPanelView: View {
    @ObservedObject var model: AudioMixerModel
    var onQuit: () -> Void
    var onClose: () -> Void

    /// Beyond this many app rows, the list scrolls with a fixed, screen-safe height
    /// instead of growing the popover further -- a forced `minHeight` here previously
    /// pushed the whole popover tall enough that AppKit repositioned it off the top of
    /// the screen with no way to reach the controls to close it.
    private static let maxRowsBeforeScroll = 3

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

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("SYSTEM")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)

                MasterVolumeRowView(volume: model.masterVolume, isMuted: model.isMasterMuted,
                                     onVolumeChange: { model.setMasterVolume($0) },
                                     onToggleMute: { model.toggleMasterMute() })

                if let systemRow = model.systemSoundsRow {
                    AppRowView(row: systemRow, devices: model.devices,
                               onVolumeChange: { model.setVolume($0, for: systemRow) },
                               onToggleMute: { model.toggleMute(for: systemRow) },
                               onDeviceChange: { model.setOutputDevice($0, for: systemRow) })
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("APPLICATIONS")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("VOLUME")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)

                if model.apps.isEmpty {
                    Text("No apps currently playing audio")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                } else if model.apps.count <= Self.maxRowsBeforeScroll {
                    // Plain VStack, no ScrollView: lets SwiftUI size the popover to
                    // its true natural height with no ambiguity, which is what
                    // actually guarantees no scrollbar up to this many rows.
                    VStack(spacing: 2) {
                        ForEach(model.apps) { row in
                            AppRowView(row: row, devices: model.devices,
                                       onVolumeChange: { model.setVolume($0, for: row) },
                                       onToggleMute: { model.toggleMute(for: row) },
                                       onDeviceChange: { model.setOutputDevice($0, for: row) })
                        }
                    }
                    .padding(.bottom, 8)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(model.apps) { row in
                                AppRowView(row: row, devices: model.devices,
                                           onVolumeChange: { model.setVolume($0, for: row) },
                                           onToggleMute: { model.toggleMute(for: row) },
                                           onDeviceChange: { model.setOutputDevice($0, for: row) })
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .frame(height: 260) // fixed, screen-safe; longer lists scroll within this
                }
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

@available(macOS 14.2, *)
private struct MasterVolumeRowView: View {
    let volume: Float
    let isMuted: Bool
    let onVolumeChange: (Float) -> Void
    let onToggleMute: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 17))
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
            Image(nsImage: row.icon)
                .resizable()
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6))
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
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}
