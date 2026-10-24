import SwiftUI

@available(macOS 14.2, *)
struct InputTabView: View {
    @ObservedObject var model: InputMixEngine

    private static let maxRowsBeforeScroll = 3

    var body: some View {
        Group {
            if !model.isDeviceInstalled {
                NotInstalledView(model: model)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("MICROPHONE")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.top, 10)

                        MicRowView(sensitivity: model.micSensitivity, isMuted: model.isMicMuted,
                                   onSensitivityChange: { model.micSensitivity = $0 },
                                   onToggleMute: { model.toggleMicMute() })
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("ADD APP AUDIO TO MIC")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.top, 10)

                        if model.apps.isEmpty {
                            Text("No apps currently playing audio")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                                .padding(.horizontal, 14)
                                .padding(.bottom, 14)
                        } else if model.apps.count <= Self.maxRowsBeforeScroll {
                            VStack(spacing: 2) {
                                ForEach(model.apps) { row in
                                    MicMixAppRowView(row: row,
                                                      onToggleInclude: { model.toggleInclude(for: row) },
                                                      onVolumeChange: { model.setMixVolume($0, for: row) })
                                }
                            }
                            .padding(.bottom, 8)
                        } else {
                            ScrollView {
                                VStack(spacing: 2) {
                                    ForEach(model.apps) { row in
                                        MicMixAppRowView(row: row,
                                                          onToggleInclude: { model.toggleInclude(for: row) },
                                                          onVolumeChange: { model.setMixVolume($0, for: row) })
                                    }
                                }
                                .padding(.bottom, 8)
                            }
                            .frame(height: 260)
                        }

                        Text("Select \u{201C}Volume Control Mic Mix\u{201D} as the microphone in your call app to send this mix.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 10)
                    }
                }
            }
        }
        .onAppear { model.activate() }
    }
}

@available(macOS 14.2, *)
private struct NotInstalledView: View {
    @ObservedObject var model: InputMixEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Virtual mic device not installed", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)

            Text("Mixing app audio into your mic needs a small virtual audio device, installed once into /Library/Audio/Plug-Ins/HAL. This needs your admin password -- macOS will ask for it directly, nothing runs silently.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if let error = model.installError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            Button(action: { model.installVirtualDevice() }) {
                if model.isInstalling {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Installing\u{2026}")
                    }
                } else {
                    Text("Install Virtual Mic Device")
                }
            }
            .disabled(model.isInstalling)
        }
        .padding(14)
    }
}

@available(macOS 14.2, *)
private struct MicRowView: View {
    let sensitivity: Float
    let isMuted: Bool
    let onSensitivityChange: (Float) -> Void
    let onToggleMute: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "mic.fill")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .opacity(isMuted ? 0.5 : 1.0)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Mic Sensitivity")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .opacity(isMuted ? 0.5 : 1.0)

                    Spacer()

                    Button(action: onToggleMute) {
                        Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(isMuted ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isMuted ? "Unmute mic" : "Mute mic")

                    Text("\(Int(sensitivity * 100))%")
                        .font(.system(size: 11, weight: .regular).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                        .opacity(isMuted ? 0.5 : 1.0)
                }

                Slider(value: Binding(get: { sensitivity }, set: onSensitivityChange), in: 0...2)
                    .opacity(isMuted ? 0.5 : 1.0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

@available(macOS 14.2, *)
private struct MicMixAppRowView: View {
    let row: MicMixAppRow
    let onToggleInclude: () -> Void
    let onVolumeChange: (Float) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: row.icon)
                .resizable()
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .opacity(row.isIncluded ? 1.0 : 0.5)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .opacity(row.isIncluded ? 1.0 : 0.5)

                    Spacer()

                    Text("\(Int(row.mixVolume * 100))%")
                        .font(.system(size: 11, weight: .regular).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                        .opacity(row.isIncluded ? 1.0 : 0.5)

                    Toggle("", isOn: Binding(get: { row.isIncluded }, set: { _ in onToggleInclude() }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.mini)
                }

                Slider(value: Binding(get: { row.mixVolume }, set: onVolumeChange), in: 0...1)
                    .opacity(row.isIncluded ? 1.0 : 0.5)
                    .disabled(!row.isIncluded)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}
