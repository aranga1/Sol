import SwiftUI

// ── Breathing ambient background ──────────────────────────────────────────────
// Implements the design spec from design_handoff_breathing_background/README.md.
// Three stacked layers, all centered, pointer-events: none.
//
// breath = 0.5 + 0.5 * sin(t / 3.1)   → ~19.5 s full cycle
// rings: f = (t/5.2 + phase) mod 1     → 5.2 s each, ⅓ staggered
// sway:  sin(t / 7) * 2.2°             → ~44 s full cycle

struct BreathingBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var t: Double = 0

    // Pulse ring phases (A=0, B=1/3, C=2/3 of 5.2 s cycle)
    private let ringPhases: [Double] = [0.0, 1.0/3.0, 2.0/3.0]
    private let ringColors: [Color] = [
        Color(red: 162/255, green: 62/255,  blue: 45/255),   // terracotta
        Color(red: 181/255, green: 112/255, blue: 31/255),   // amber
        Color(red: 140/255, green: 51/255,  blue: 34/255),   // deep terracotta
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                glowLayer
                ringLayers
                markLayer
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { return }
            // 60 fps drive via a 1/60 timer
            Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
                t += 1.0 / 60.0
            }
        }
    }

    // ── Layer 1: Warm glow ────────────────────────────────────────────────────
    private var glowLayer: some View {
        let breath = reduceMotion ? 0.75 : 0.5 + 0.5 * sin(t / 3.1)
        let scale  = 1 + breath * 0.14
        let alpha  = 0.5 + breath * 0.45

        return Circle()
            .fill(
                RadialGradient(
                    stops: [
                        .init(color: Color(red: 181/255, green: 112/255, blue: 31/255, opacity: 0.22 * alpha / 0.95), location: 0),
                        .init(color: Color(red: 162/255, green: 62/255,  blue: 45/255, opacity: 0.06 * alpha / 0.95), location: 0.46),
                        .init(color: .clear, location: 0.70),
                    ],
                    center: .center, startRadius: 0, endRadius: 170
                )
            )
            .frame(width: 340, height: 340)
            .opacity(alpha)
            .scaleEffect(scale)
            .blur(radius: 8)
    }

    // ── Layer 2: Pulse rings ──────────────────────────────────────────────────
    private var ringLayers: some View {
        ForEach(0..<3, id: \.self) { i in
            let f = reduceMotion ? 0 : (t / 5.2 + ringPhases[i]).truncatingRemainder(dividingBy: 1)
            let s = 0.5 + f * 2.3
            let opacity: Double = reduceMotion ? 0 : {
                if f < 0.1 { return (f / 0.1) * 0.5 }
                return max(0, 1 - (f - 0.1) / 0.9) * 0.5
            }()

            Circle()
                .stroke(ringColors[i].opacity(i == 0 ? 0.24 : i == 1 ? 0.22 : 0.18),
                        lineWidth: 1.5)
                .frame(width: 172, height: 172)
                .scaleEffect(s)
                .opacity(opacity)
        }
    }

    // ── Layer 3: Node-sun mark ────────────────────────────────────────────────
    private var markLayer: some View {
        let breath   = reduceMotion ? 0.75 : 0.5 + 0.5 * sin(t / 3.1)
        let scale    = 1 + breath * 0.05
        let rotation = reduceMotion ? 0.0 : sin(t / 7) * 2.2

        return Image("node-sun")
            .resizable()
            .scaledToFit()
            .frame(width: 236, height: 236)
            .opacity(0.52)
            .scaleEffect(scale)
            .rotationEffect(.degrees(rotation))
    }
}
