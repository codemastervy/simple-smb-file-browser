import SwiftUI

/// Liquid Glass surfaces, with material fallbacks.
///
/// The real Glass APIs (`glassEffect`, `GlassEffectContainer`,
/// `.buttonStyle(.glass)`) only exist from iOS 26 / macOS 26, and this app
/// deploys back to iOS 17 / macOS 14 — so every glass surface is gated and falls
/// back to the closest material. Verified against the Xcode 26.5 SDK.
extension View {
    /// A raised panel: transfers panel, modals, inspector cards.
    func glassPanel(cornerRadius: CGFloat = 18) -> some View {
        modifier(GlassPanelModifier(cornerRadius: cornerRadius, isProminent: true))
    }

    /// A lighter surface for bars that sit over content — breadcrumbs, toolbars.
    func glassBar(cornerRadius: CGFloat = 0) -> some View {
        modifier(GlassPanelModifier(cornerRadius: cornerRadius, isProminent: false))
    }

    /// Continuous-corner clip, used consistently so nothing gets circular
    /// corners by accident.
    func continuousCorners(_ radius: CGFloat) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Subtle depth. Kept low-contrast so it reads as elevation rather than
    /// a drop shadow, and so it survives Dark Mode.
    func softDepth(_ level: CGFloat = 1) -> some View {
        shadow(color: .black.opacity(0.10 * level), radius: 8 * level, x: 0, y: 3 * level)
    }
}

private struct GlassPanelModifier: ViewModifier {
    let cornerRadius: CGFloat
    let isProminent: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(isProminent ? .regular : .regular.interactive(), in: shape)
        } else {
            content
                .background(isProminent ? .regularMaterial : .ultraThinMaterial, in: shape)
                .overlay(
                    shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                )
        }
    }
}

/// Wraps sibling glass surfaces so they blend into each other where supported.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// Applies the glass button style where available.
struct GlassButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

extension View {
    func glassButton() -> some View { modifier(GlassButtonModifier()) }
}
