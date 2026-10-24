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

            Divider()

            if model.apps.isEmpty {
                Text("No apps currently playing audio")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.apps) { row in
                            AppRowView(row: row, onVolumeChange: { model.setVolume($0, for: row) })
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
        .frame(width: 280)
    }
}

@available(macOS 14.2, *)
private struct AppRowView: View {
    let row: AppRow
    let onVolumeChange: (Float) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: row.icon)
                .resizable()
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(get: { row.volume }, set: onVolumeChange), in: 0...1)
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}
