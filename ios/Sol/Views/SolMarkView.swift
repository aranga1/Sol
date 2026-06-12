import SwiftUI
import UIKit

/// Sol node-sun mark that adapts to the current iOS appearance:
/// - Light mode               → mark-color  (terracotta + amber, from xcassets)
/// - Dark mode                → mark-cream  (cream + amber, from xcassets dark slot)
/// - High contrast            → mark-mono   as template (tinted by system/user color)
/// - Smart Invert / Inverted  → mark-mono   as template
struct SolMarkView: View {
    var size: CGFloat = 128
    var opacity: Double = 1.0

    @Environment(\.colorSchemeContrast) private var contrast

    // UIKit gives us the most reliable invert-colors detection
    private var invertColorsEnabled: Bool {
        UIAccessibility.isInvertColorsEnabled
    }

    private var useMonoTemplate: Bool {
        contrast == .increased || invertColorsEnabled
    }

    var body: some View {
        Group {
            if useMonoTemplate {
                // Render mono mark as template so it adopts the system tint/foreground
                Image("node-sun")
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(DS.inkDark)
            } else {
                // xcassets automatically picks mark-color (light) or mark-cream (dark)
                Image("SolMark")
                    .resizable()
            }
        }
        .scaledToFit()
        .frame(width: size, height: size)
        .opacity(opacity)
    }
}
