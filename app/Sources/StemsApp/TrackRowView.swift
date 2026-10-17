import SwiftUI

/// One compact track row (52pt): color bar, name + state, waveform, mute, volume, save.
/// Pure view over plain values so it previews without a player.
public struct TrackRowView: View {
    var name: String
    var color: Color
    var peaks: [Float]
    var progress: Double
    var muted: Bool
    var volume: Double
    var showSave: Bool
    var onMute: () -> Void
    var onVolume: (Double) -> Void
    var onSeek: (Double) -> Void
    var onSave: () -> Void

    public init(name: String, color: Color, peaks: [Float], progress: Double,
                muted: Bool, volume: Double, showSave: Bool,
                onMute: @escaping () -> Void,
                onVolume: @escaping (Double) -> Void, onSeek: @escaping (Double) -> Void,
                onSave: @escaping () -> Void) {
        self.name = name
        self.color = color
        self.peaks = peaks
        self.progress = progress
        self.muted = muted
        self.volume = volume
        self.showSave = showSave
        self.onMute = onMute
        self.onVolume = onVolume
        self.onSeek = onSeek
        self.onSave = onSave
    }

    private var stateText: String {
        if muted { return "Muted" }
        return "\(Int((volume * 100).rounded()))%"
    }

    public var body: some View {
        HStack(spacing: 10) {
            // Name + waveform (dimmed when muted; controls stay fully visible)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(Fonts.body(14, .semibold))
                        .foregroundStyle(Theme.text)
                    Text(stateText)
                        .font(Fonts.body(11, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textFaint)
                }
                .frame(width: 62, alignment: .leading)

                WaveformView(peaks: peaks, progress: progress, color: color, onSeek: onSeek)
                    .frame(height: 36)
                    .padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.bg))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .opacity(muted ? 0.45 : 1)

            // Audible = track color, muted = neutral (same rule everywhere).
            ChipToggle(on: !muted, tint: color, action: onMute) {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .help("Mute")

            VolumeSlider(value: Binding(get: { volume }, set: onVolume), tint: color)
                .frame(width: 92)

            if showSave {
                Button(action: onSave) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.surfaceHi))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Theme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .modifier(Hoverable())
                .help("Save this stem as WAV")
            } else {
                Color.clear.frame(width: 26, height: 26)
            }
        }
        .padding(.vertical, 8)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .background(Theme.surface)
        // 4pt color bar on the left edge, the web player's track marker.
        .overlay(alignment: .leading) {
            Rectangle().fill(color).frame(width: 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: muted)
    }
}

#Preview("track row") {
    VStack(spacing: 6) {
        TrackRowView(
            name: "Vocals", color: StemStyle.at(4).color,
            peaks: (0 ..< 800).map { Float(abs(sin(Double($0) / 20)) * (0.3 + 0.7 * abs(sin(Double($0) / 131)))) },
            progress: 0.35, muted: false, volume: 1.0, showSave: true,
            onMute: {}, onVolume: { _ in }, onSeek: { _ in }, onSave: {}
        )
        TrackRowView(
            name: "Drums", color: StemStyle.at(1).color,
            peaks: (0 ..< 800).map { Float(abs(sin(Double($0) / 9)) * 0.7) },
            progress: 0.35, muted: true, volume: 1.0, showSave: true,
            onMute: {}, onVolume: { _ in }, onSeek: { _ in }, onSave: {}
        )
    }
    .preferredColorScheme(.dark)
    .padding()
    .frame(width: 760)
    .background(Theme.bg)
}
