import SwiftUI

/// Small square toggle used for Solo / Mute (flat M / S buttons).
struct ChipToggle<Label: View>: View {
    var on: Bool
    var tint: Color
    var action: () -> Void
    var label: () -> Label

    init(on: Bool, tint: Color, action: @escaping () -> Void,
         @ViewBuilder label: @escaping () -> Label) {
        self.on = on
        self.tint = tint
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            label()
                .font(Fonts.body(12, .semibold))
                .foregroundStyle(on ? Theme.onColor : Theme.text)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(on ? tint : Theme.surfaceHi))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(on ? tint : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .modifier(Hoverable())
    }
}

/// Like ChipToggle, but holding it repeats the action: first after 0.4 s, then faster and faster.
struct HoldChip<Label: View>: View {
    var action: () -> Void
    var label: () -> Label
    @State private var repeater: Task<Void, Never>?

    init(action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.action = action
        self.label = label
    }

    var body: some View {
        label()
            .font(Fonts.body(12, .semibold))
            .foregroundStyle(Theme.text)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.surfaceHi))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
            .modifier(Hoverable())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in start() }
                .onEnded { _ in stop() })
            .onDisappear { stop() }
    }

    private func start() {
        guard repeater == nil else { return }
        action()
        repeater = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            var interval = 0.16
            while !Task.isCancelled {
                action()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                interval = max(0.035, interval * 0.93) // ~6/s -> ~28/s
            }
        }
    }

    private func stop() {
        repeater?.cancel()
        repeater = nil
    }
}

/// Glyph for the on-beat / off-beat switch: two beat bars with a tick between them.
/// On-beat lights the bars, off-beat lights the tick.
struct BeatPhaseGlyph: View {
    var offbeat: Bool

    var body: some View {
        HStack(spacing: 3) {
            Capsule().frame(width: 2, height: offbeat ? 6 : 14).opacity(offbeat ? 0.4 : 1)
            Capsule().frame(width: 2, height: offbeat ? 14 : 6).opacity(offbeat ? 1 : 0.4)
            Capsule().frame(width: 2, height: offbeat ? 6 : 14).opacity(offbeat ? 0.4 : 1)
        }
        .frame(height: 16)
    }
}

/// Thin volume slider, range 0...1.5, with a tick and snap at unity gain (1.0).
struct VolumeSlider: View {
    @Binding var value: Double
    var tint: Color
    private let maxValue = 1.5

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let frac = CGFloat(min(max(value / maxValue, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line).frame(height: 4)
                Capsule().fill(tint).frame(width: max(4, w * frac), height: 4)
                Rectangle().fill(Color.white.opacity(0.30))
                    .frame(width: 1, height: 10)
                    .offset(x: w * CGFloat(1 / maxValue) - 0.5)
                Circle().fill(tint)
                    .frame(width: 12, height: 12)
                    .offset(x: w * frac - 6)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                var v = Double(min(1, max(0, g.location.x / w))) * maxValue
                if abs(v - 1) < 0.04 { v = 1 }
                value = v
            })
        }
        .frame(height: 20)
    }
}

/// Global seek bar in the transport.
struct Scrubber: View {
    var progress: Double
    var onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let p = CGFloat(min(max(progress, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line).frame(height: 4)
                Capsule().fill(Theme.text).frame(width: max(4, w * p), height: 4)
                Circle().fill(Theme.text)
                    .frame(width: 10, height: 10)
                    .offset(x: w * p - 5)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                onSeek(Double(min(1, max(0, g.location.x / w))))
            })
        }
        .frame(height: 14)
    }
}

/// Flat on/off button with a text/icon label (e.g. Metronome): light fill when on.
struct ToggleButton<Content: View>: View {
    var on: Bool
    var action: () -> Void
    var content: () -> Content

    init(on: Bool, action: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.on = on
        self.action = action
        self.content = content
    }

    var body: some View {
        Button(action: action) {
            content()
                .font(Fonts.body(13, .semibold))
                .foregroundStyle(on ? Theme.bg : Theme.text)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(on ? Theme.text : Theme.surfaceHi))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(on ? Theme.text : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .modifier(Hoverable())
    }
}
