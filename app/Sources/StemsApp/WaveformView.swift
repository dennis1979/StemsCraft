import SwiftUI

/// Bar-style waveform with a playhead; click or drag to seek.
/// Played part is drawn at full color, the rest dimmed.
public struct WaveformView: View {
    var peaks: [Float]
    var progress: Double // 0..1 playhead
    var color: Color
    var onSeek: (Double) -> Void

    public init(peaks: [Float], progress: Double, color: Color, onSeek: @escaping (Double) -> Void) {
        self.peaks = peaks
        self.progress = progress
        self.color = color
        self.onSeek = onSeek
    }

    public var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let mid = size.height / 2
                let barW: CGFloat = 2
                let step: CGFloat = 3
                let count = max(1, Int(size.width / step))
                let headX = CGFloat(min(max(progress, 0), 1)) * size.width
                let n = peaks.count

                guard n > 0 else {
                    // No data yet: a quiet center line.
                    let line = CGRect(x: 0, y: mid - 0.5, width: size.width, height: 1)
                    ctx.fill(Path(line), with: .color(color.opacity(0.25)))
                    return
                }

                for b in 0 ..< count {
                    let a = b * n / count
                    let e = min(n, max(a + 1, (b + 1) * n / count))
                    var v: Float = 0
                    for k in a ..< e { v = max(v, peaks[k]) }
                    let h = max(1.5, CGFloat(pow(Double(min(1, v)), 0.85)) * mid * 0.92)
                    let x = CGFloat(b) * step
                    let rect = CGRect(x: x, y: mid - h, width: barW, height: h * 2)
                    let played = x + barW <= headX
                    ctx.fill(Path(roundedRect: rect, cornerRadius: barW / 2),
                             with: .color(color.opacity(played ? 1 : 0.55)))
                }

                // Playhead (flat white line, like the web player).
                ctx.fill(Path(CGRect(x: headX - 0.75, y: 0, width: 1.5, height: size.height)),
                         with: .color(Color.white))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                onSeek(min(1, max(0, g.location.x / geo.size.width)))
            })
        }
    }
}
