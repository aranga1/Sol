import SwiftUI

// ── Alysha Design System ───────────────────────────────────────────────────────
// Warm parchment + terracotta/amber palette. Newsreader for display, SF Pro body.

enum DS {
    // ── Colors ─────────────────────────────────────────────────────────────────
    static let parchment       = Color(hex: "#F1E8D9")
    static let parchmentDeep   = Color(hex: "#EEE3D0")
    static let parchmentCard   = Color(hex: "#FCF8EF")
    static let parchmentMid    = Color(hex: "#F3EBDC")

    static let terracotta      = Color(hex: "#A23E2D")
    static let terracottaBright = Color(hex: "#AB4232")
    static let terracottaDark  = Color(hex: "#8C3322")
    static let terracottaFaint = Color(hex: "#A23E2D").opacity(0.08)

    static let amber           = Color(hex: "#B5701F")

    static let espresso        = Color(hex: "#221C17")
    static let espressoDeep    = Color(hex: "#1B1815")

    static let inkDark         = Color(hex: "#2B2521")
    static let inkMid          = Color(hex: "#3A342E")
    static let inkLight        = Color(hex: "#7C7468")
    static let inkFaint        = Color(hex: "#A0937F")
    static let inkWarm         = Color(hex: "#C0995F")

    // ── Gradients ──────────────────────────────────────────────────────────────
    static let terracottaGradient = LinearGradient(
        colors: [Color(hex: "#AB4232"), Color(hex: "#8C3322")],
        startPoint: .top, endPoint: .bottom
    )
    static let glassGradient = LinearGradient(
        colors: [Color.white.opacity(0.62), Color.white.opacity(0.46)],
        startPoint: .top, endPoint: .bottom
    )

    // ── Typography ─────────────────────────────────────────────────────────────
    // Newsreader variable font — bundled as Newsreader.ttf + Newsreader-Italic.ttf
    // PostScript names: Newsreader16pt-Regular / Newsreader16pt-Italic
    // Weight axis (wght 300–800) is controlled via SwiftUI's .fontWeight() modifier.
    static func newsreader(_ size: CGFloat, weight: Font.Weight = .medium, italic: Bool = false) -> Font {
        let psName = italic ? "Newsreader16pt-Italic" : "Newsreader16pt-Regular"
        return .custom(psName, size: size).weight(weight)
    }

    // ── Corner radii ───────────────────────────────────────────────────────────
    static let radiusBar:    CGFloat = 28
    static let radiusPop:    CGFloat = 30
    static let radiusCard:   CGFloat = 18
    static let radiusSheet:  CGFloat = 26
    static let radiusButton: CGFloat = 16

    // ── Shadows ────────────────────────────────────────────────────────────────
    static func barShadow() -> some View {
        RoundedRectangle(cornerRadius: radiusBar)
            .fill(Color.clear)
            .shadow(color: Color(hex: "#50321E").opacity(0.42), radius: 34, x: 0, y: 16)
    }
}

// ── Color hex init ─────────────────────────────────────────────────────────────
extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xff) / 255
        let g = Double((int >> 8)  & 0xff) / 255
        let b = Double(int         & 0xff) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// ── Liquid-glass button background ────────────────────────────────────────────
struct GlassBackground: ViewModifier {
    var cornerRadius: CGFloat = 21
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(DS.glassGradient)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(Color.white.opacity(0.62), lineWidth: 1)
                    )
                    .shadow(color: Color(hex: "#50321E").opacity(0.32), radius: 16, x: 0, y: 5)
            )
    }
}

extension View {
    func glassBackground(cornerRadius: CGFloat = 21) -> some View {
        modifier(GlassBackground(cornerRadius: cornerRadius))
    }
}
