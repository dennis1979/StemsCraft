import SwiftUI

// MARK: - Color helper

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

// MARK: - Design tokens (graphite palette)

enum Theme {
    static let bg = Color(hex: 0x1B1E25)        // --bg
    static let surface = Color(hex: 0x242832)   // --panel
    static let surfaceHi = Color(hex: 0x2C313C) // --panel-2
    static let line = Color(hex: 0x3A4050)      // --line
    static let lineHi = Color(hex: 0x525A6D)

    static let text = Color(hex: 0xE9E5DC)      // --text
    static let textDim = Color(hex: 0x8D93A3)   // --dim
    static let textFaint = Color(hex: 0x6B7283)

    static let accent = Color(hex: 0xE86BB5)    // --vocals pink, used for highlights
    static let sky = Color(hex: 0x7DD3FC)       // metronome mark: sky blue, no stem uses it
    static let good = Color(hex: 0x78D68C)
    static let warn = Color(hex: 0xE2CF4F)
    static let bad = Color(hex: 0xFF5A5F)       // --red
    static let onColor = Color(hex: 0x16181D)   // dark text on a colored fill

    // Kept so older call sites keep compiling.
    static let stroke = line
    static let strokeHi = lineHi
}

/// Barlow / Barlow Condensed, bundled in Contents/Resources/Fonts by package.sh.
/// When the fonts are not installed (e.g. `swift run`) SwiftUI falls back to the system font.
enum Fonts {
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        switch weight {
        case .regular, .light, .thin, .ultraLight: return .custom("Barlow-Regular", fixedSize: size)
        case .medium: return .custom("Barlow-Medium", fixedSize: size)
        default: return .custom("Barlow-SemiBold", fixedSize: size)
        }
    }

    static func condensed(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "BarlowCondensed-Bold" : "BarlowCondensed-SemiBold", fixedSize: size)
    }
}

/// Per-track identity. Index 0 is the original mix, 1...4 are the stems
/// in the order the separator returns them (drums, bass, other, vocals).
/// Graphite palette.
struct StemStyle {
    let name: String
    let icon: String
    let color: Color

    static let all: [StemStyle] = [
        StemStyle(name: "Original", icon: "music.note", color: Color(hex: 0xB9B4AA)),
        StemStyle(name: "Drums", icon: "metronome.fill", color: Color(hex: 0xF0A23B)),
        StemStyle(name: "Bass", icon: "waveform.path", color: Color(hex: 0x6F8CF7)),
        StemStyle(name: "Other", icon: "pianokeys", color: Color(hex: 0x5CC3B6)),
        StemStyle(name: "Vocals", icon: "mic.fill", color: Color(hex: 0xE86BB5)),
    ]

    static func at(_ i: Int) -> StemStyle { all[((i % all.count) + all.count) % all.count] }
}

// MARK: - Logo (matches the app icon palette, independent of the UI palette)

/// The Stems mark: four capsules, one per stem, drawn as a waveform that has been pulled apart.
/// Geometry matches Assets/logo-mark.svg (534 x 540 design units).
struct LogoMark: View {
    var size: CGFloat = 40

    private static let bars: [(x: CGFloat, y: CGFloat, h: CGFloat, top: UInt32, bottom: UInt32)] = [
        (0, 192, 280, 0xFF8A73, 0xFF4D5E),
        (146, 0, 540, 0x6FA8FF, 0x3A5BFF),
        (292, 100, 420, 0x5CF0C0, 0x18B58E),
        (438, 152, 215, 0xFFD36B, 0xFF9F1A),
    ]

    var body: some View {
        Canvas { ctx, sz in
            let s = min(sz.width, sz.height) / 540
            let ox = (sz.width - 534 * s) / 2
            let oy = (sz.height - 540 * s) / 2
            for b in LogoMark.bars {
                let rect = CGRect(x: ox + b.x * s, y: oy + b.y * s, width: 96 * s, height: b.h * s)
                let path = Path(roundedRect: rect, cornerRadius: 48 * s)
                ctx.fill(path, with: .linearGradient(
                    Gradient(colors: [Color(hex: b.top), Color(hex: b.bottom)]),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY),
                    endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Backgrounds & surfaces

struct AppBackground: View {
    var body: some View {
        Theme.bg.ignoresSafeArea()
    }
}

extension View {
    /// Flat panel, optional hairline border.
    func surfaceCard(cornerRadius: CGFloat = 8,
                     fill: Color = Theme.surface,
                     border: Color = Color.clear,
                     borderWidth: CGFloat = 1) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(border, lineWidth: borderWidth))
    }
}

// MARK: - Buttons

struct Hoverable: ViewModifier {
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .brightness(hover ? 0.08 : 0)
            .onHover { hover = $0 }
    }
}

/// Light fill, dark text: primary button.
struct PrimaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Fonts.body(compact ? 13 : 14, .semibold))
            .foregroundStyle(Theme.bg)
            .padding(.horizontal, compact ? 14 : 18)
            .padding(.vertical, compact ? 5 : 9)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.text))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .modifier(Hoverable())
    }
}

/// Flat secondary button with a hairline border.
struct PillButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Fonts.body(13, .regular))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 3 : 5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(configuration.isPressed ? Theme.line : Theme.surfaceHi))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1))
            .modifier(Hoverable())
    }
}
