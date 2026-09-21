import AppKit
import SwiftUI

// Broadsheet, the design system the Field Notes mockup is drawn in.
// Light values are the stylesheet's own. Dark is derived in spec 0003, because Broadsheet has none.
nonisolated enum Broadsheet {

    // Every colour is one dynamic value that resolves against the current appearance.
    enum Colors {
        static let background = dynamic(light: 0xF3_F2_F2, dark: 0x1A_19_18)
        static let surface = dynamic(light: 0xEA_E9_E9, dark: 0x25_23_22)
        static let text = dynamic(light: 0x20_1E_1D, dark: 0xEC_E9_E8)

        // neutral-700 in light rather than Broadsheet's neutral-600, which fails AA at body size.
        static let secondaryText = dynamic(light: 0x60_5D_5D, dark: 0x9B_97_97)

        // Light cyan measures 3.65:1, so it is never used for body sized text. See accentText.
        static let accent = dynamic(light: 0x00_88_B0, dark: 0x62_C5_EE)

        // The accent that passes AA at body size in both appearances.
        static let accentText = dynamic(light: 0xD6_00_6C, dark: 0xFF_90_B1)

        static let divider = dynamicAlpha(light: 0x20_1E_1D, dark: 0xEC_E9_E8, alpha: 0.16)

        // The shared neutral ramp. Step is the stylesheet's own naming, 100 through 900. Dark mode
        // walks it from the other end, so a step keeps its contrast against the background.
        static func neutral(_ step: Int) -> Color {
            let index = max(0, min(8, step / 100 - 1))
            return dynamic(light: neutralRamp[index], dark: neutralRamp[8 - index])
        }

        private static let neutralRamp = [
            0xF8_F4_F4, 0xEA_E7_E7, 0xD7_D3_D3, 0xBA_B6_B6, 0x9B_97_97,
            0x7D_79_79, 0x60_5D_5D, 0x44_41_41, 0x2D_2B_2B,
        ]
    }

    // The stylesheet's scale. Body is 15 at 1.55 line height.
    enum TypeScale {
        static let body: CGFloat = 15
        static let bodyLineHeight: CGFloat = 1.55
        static let heading: [CGFloat] = [42, 32, 25, 20, 16, 13]
        static let uiLarge: CGFloat = 14
        static let uiSmall: CGFloat = 11
    }

    // Broadsheet's 5pt scale.
    enum Space {
        static let x1: CGFloat = 5
        static let x2: CGFloat = 10
        static let x3: CGFloat = 15
        static let x4: CGFloat = 20
        static let x6: CGFloat = 30
        static let x8: CGFloat = 40
    }

    // Near square on purpose. This is most of why the app will not look like default SwiftUI.
    enum Radius {
        static let small: CGFloat = 1
        static let medium: CGFloat = 2
        static let large: CGFloat = 4
    }

    // Source Serif 4 for headings and body alike, as Broadsheet specifies.
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard AppFonts.isRegistered else {
            return .system(size: size, weight: weight, design: .serif)
        }
        return .custom(AppFonts.familyName, size: size).weight(weight)
    }

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(rgb: appearance.isDark ? dark : light)
        })
    }

    private static func dynamicAlpha(light: Int, dark: Int, alpha: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(rgb: appearance.isDark ? dark : light).withAlphaComponent(alpha)
        })
    }
}

nonisolated extension NSAppearance {
    // bestMatch is the supported way to ask, because a named appearance can be a vibrant variant.
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

nonisolated extension NSColor {
    fileprivate convenience init(rgb: Int) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
