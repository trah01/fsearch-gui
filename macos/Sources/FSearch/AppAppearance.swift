import SwiftUI
import AppKit

enum AppAppearance {
    static func native(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: alpha)
        }
    }

    static let background = Color(nsColor: native(0xFFFFFF, 0x1C1C1E))
    static var secondary: Color { Color(nsColor: native(0xFFFFFF, 0x303030)) }
    static var panel: Color { Color(nsColor: native(0xFFFFFF, 0x252525)) }
    static let text = Color(nsColor: native(0x202020, 0xF2F2F2))
    static let muted = Color(nsColor: native(0x6E6E73, 0xA1A1A6))
    static let separator = Color(nsColor: native(0xA6A6AB, 0x808085, alpha: 0.22))
    static var accent: Color { Color(nsColor: nativeAccent) }
    static var onAccent: Color {
        AppearanceSettings.savedTheme == .white ? Color(nsColor: native(0xFFFFFF, 0x202020)) : .white
    }
    static var nativeAccent: NSColor {
        let theme = AppearanceSettings.savedTheme
        return native(theme.light, theme.dark)
    }
    static var selection: Color { Color(nsColor: nativeSelection) }
    static var nativeSelection: NSColor { tinted(0xFFFFFF, 0x252525, fraction: 0.27, alpha: 0.85) }
    static var sidebarSelection: Color { Color(nsColor: tinted(0xECECEE, 0x303030, fraction: 0.12, alpha: 0.8)) }

    static func tinted(_ light: UInt32, _ dark: UInt32, fraction: CGFloat, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let theme = AppearanceSettings.savedTheme
            func rgb(_ value: UInt32) -> NSColor {
                NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                    green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
            }
            return (rgb(isDark ? dark : light).blended(withFraction: fraction,
                of: rgb(isDark ? theme.dark : theme.light)) ?? rgb(isDark ? dark : light)).withAlphaComponent(alpha)
        }
    }
    static let border = Color(nsColor: native(0xDADCE0, 0x48484A))
    static let shadow = Color(nsColor: native(0x000000, 0x000000, alpha: 0.13))
    static let corner: CGFloat = 22
    static let searchHeight: CGFloat = 48
    static let searchCorner: CGFloat = 16
    static let searchFontSize: CGFloat = 15
    static let sidebarFontSize: CGFloat = 12
    static let sidebarRowHeight: CGFloat = 32
    static let rowHeight: CGFloat = 54
    static let rowAlternate = native(0xE5E5EA, 0x2C2C2E, alpha: 0.22)
    static let nativeText = native(0x202020, 0xF2F2F2)
    static let nativeMuted = native(0x6E6E73, 0xA1A1A6)
}

struct SearchBackdrop: View {
    var body: some View {
        AppAppearance.background.allowsHitTesting(false)
    }
}

extension View {
    func floatingSurface(radius: CGFloat = AppAppearance.corner, shadow: Bool = true) -> some View {
        self.background(AppAppearance.panel, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(AppAppearance.border, lineWidth: 1)
                .allowsHitTesting(false))
            .shadow(color: shadow ? AppAppearance.shadow : .clear, radius: 16, x: 0, y: 7)
    }
}

struct FloatingButtonStyle: ButtonStyle {
    var radius: CGFloat = 12
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? AppAppearance.onAccent : AppAppearance.text)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(prominent ? AppAppearance.accent : AppAppearance.secondary)
            }
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(prominent ? Color.white.opacity(0.3) : AppAppearance.separator, lineWidth: 1))
            .shadow(color: AppAppearance.shadow.opacity(configuration.isPressed ? 0.3 : 0.7), radius: 6, x: 0, y: 3)
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
