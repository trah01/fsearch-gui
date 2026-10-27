import SwiftUI

/// Shared compact window controls, with emphasis only during interaction.
struct WindowToolbarButtonStyle: ButtonStyle {
    var active = true
    var compact = true
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.label
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(active ? AppAppearance.text.opacity(0.85) : AppAppearance.muted)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(configuration.isPressed ? 0.14 : hovered ? 0.08 : 0),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(focused ? AppAppearance.accent.opacity(0.7) : .clear, lineWidth: 1.5))
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovered = $0 }
        } else {
            configuration.label
        }
    }
}
