import SwiftUI

@available(macOS 14.2, *)
struct MixerPanelView: View {
    @ObservedObject var model: AudioMixerModel
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Volume Control")
                .font(.system(size: 15, weight: .bold))
                .padding([.top, .horizontal], 14)
                .padding(.bottom, 10)

            Divider()

            if let systemRow = model.systemSoundsRow {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SYSTEM")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)

                    AppRowView(row: systemRow, devices: model.devices,
                               onVolumeChange: { model.setVolume($0, for: systemRow) },
                               onToggleMute: { model.toggleMute(for: systemRow) },
                               onDeviceChange: { model.setOutputDevice($0, for: systemRow) })
                }

                Divider()
            }

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
                    .frame(maxHeight: 340)
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
                        Image(systemName: row.isMuted ? "speaker.slash.fill" : "speaker.fill")
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
                                if device.uid == row.outputDeviceUID {
                                    Label(device.name, systemImage: "checkmark")
                                } else {
                                    Text(device.name)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "hifispeaker.fill")
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
