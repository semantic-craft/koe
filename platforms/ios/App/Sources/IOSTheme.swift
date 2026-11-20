import SwiftUI
import UIKit

enum AppFontSizes {
    static let xs: CGFloat = 12
    static let sm: CGFloat = 14
    static let md: CGFloat = 16
    static let lg: CGFloat = 22
}

enum IOSRadii {
    static let control: CGFloat = 8
    static let card: CGFloat = 14
    static let pill: CGFloat = 999
}

enum IOSColors {
    static let surface0 = adaptive(light: 0xFFFFFF, dark: 0x0E0E10)
    static let surface1 = adaptive(light: 0xFFFFFF, dark: 0x18181B)
    static let bgPanel = adaptive(light: 0xF7F7F8, dark: 0x141416)
    static let bgSubtle = adaptive(light: 0xF1F1F3, dark: 0x202024)
    static let border = adaptive(light: 0xE3E3E7, dark: 0x2C2C32)
    static let accent = adaptive(light: 0x242426, dark: 0xF4F4F6)
    static let onAccent = adaptive(light: 0xFFFFFF, dark: 0x0E0E10)
    static let accentSoft = adaptive(light: 0xECECEF, dark: 0x27272C)
    static let textPrimary = adaptive(light: 0x202022, dark: 0xF4F4F6)
    static let textSecondary = adaptive(light: 0x54545B, dark: 0xB4B4BC)
    static let textMuted = adaptive(light: 0x686870, dark: 0x94949E)
    static let success = adaptive(light: 0x287447, dark: 0x4ADE80)
    static let warning = adaptive(light: 0x8A5A12, dark: 0xFBBF24)
    static let danger = adaptive(light: 0xB43D43, dark: 0xF87171)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            rgbColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    private static func rgbColor(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
