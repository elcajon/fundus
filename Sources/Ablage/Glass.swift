import SwiftUI

/// Liquid Glass ab macOS 26, davor die bisherigen Materialien. So bleibt macOS 15 als Mindestversion.
extension View {
    @ViewBuilder func glassCapsule() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: Capsule())
        } else {
            background(.regularMaterial, in: Capsule())
        }
    }

    @ViewBuilder func glassPanel(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    @ViewBuilder func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }

    /// Inhalt, der unter der Toolbar durchscrollt, weich ausblenden.
    @ViewBuilder func softTopScrollEdge() -> some View {
        if #available(macOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }

    @ViewBuilder func searchFocus(_ binding: FocusState<Bool>.Binding) -> some View {
        if #available(macOS 15, *) {
            searchFocused(binding)
        } else {
            self
        }
    }
}
