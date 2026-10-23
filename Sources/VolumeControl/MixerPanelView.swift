import SwiftUI

@available(macOS 14.2, *)
struct MixerPanelView: View {
    @ObservedObject var model: AudioMixerModel
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Volume Control")
                .font(.headline)
                .padding([.top, .horizontal], 14)
                .padding(.bottom, 8)

            DeviceStrip(devices: model.devices, selectedUID: model.defaultDeviceUID) { device in
                model.selectDefaultDevice(device)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Divider()

            if model.apps.isEmpty {
                Text("No apps currently playing audio")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.apps) { row in
                            AppRowView(row: row, devices: model.devices,
                                       onToggle: { model.toggleRouting(for: row) },
                                       onVolumeChange: { model.setVolume($0, for: row) },
                                       onDeviceChange: { model.setOutputDevice($0, for: row) })
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 320)
            }

            Divider()

            Button("Quit Volume Control", action: onQuit)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.callout)
                .padding(12)
        }
        .frame(width: 300)
    }
}

@available(macOS 14.2, *)
private struct DeviceStrip: View {
    let devices: [AudioDevice]
    let selectedUID: String?
    let onSelect: (AudioDevice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("OUTPUT")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(devices) { device in
                        let selected = device.uid == selectedUID
                        Button {
                            onSelect(device)
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "hifispeaker.fill")
                                    .font(.system(size: 18))
                                Text(device.name)
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                            .frame(width: 64)
                            .padding(.vertical, 6)
                            .background(selected ? Color.accentColor.opacity(0.2) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

@available(macOS 14.2, *)
private struct AppRowView: View {
    let row: AppRow
    let devices: [AudioDevice]
    let onToggle: () -> Void
    let onVolumeChange: (Float) -> Void
    let onDeviceChange: (AudioDevice) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: row.icon)
                .resizable()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(get: { row.volume }, set: onVolumeChange), in: 0...1)
                        .disabled(!row.isRouted)
                }
            }

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
                Image(systemName: "arrow.triangle.branch")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!row.isRouted)

            Toggle("", isOn: Binding(get: { row.isRouted }, set: { _ in onToggle() }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}
