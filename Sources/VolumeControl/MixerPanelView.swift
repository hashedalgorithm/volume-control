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
                                AppRowView(row: row, onVolumeChange: { model.setVolume($0, for: row) })
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
    let onVolumeChange: (Float) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: row.icon)
                .resizable()
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(row.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .frame(width: 84, alignment: .leading)

            Image(systemName: "speaker.fill")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            Slider(value: Binding(get: { row.volume }, set: onVolumeChange), in: 0...1)

            Text("\(Int(row.volume * 100))%")
                .font(.system(size: 11, weight: .regular).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }
}
