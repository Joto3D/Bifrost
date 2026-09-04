import SwiftUI

/// Bifrost's small design system: shared color, gradient, typography, and
/// spacing constants, plus a handful of reusable view helpers, so every
/// screen reads as one consistent "deep night sky + rainbow bridge"
/// identity (matching `Resources/icon.png`) instead of each view rolling
/// its own ad-hoc styling.
///
/// This file is presentation-only — nothing here reads or mutates any
/// model, service, or `AppState`. Behavior lives entirely in the views that
/// consume these tokens.
enum Theme {
    // MARK: - Aurora accent

    /// The signature accent: the rainbow-bridge arc from the app icon,
    /// warm red through cool violet. This is Bifrost's *one* splash of
    /// color — used sparingly (primary actions, the active-profile
    /// highlight, progress accents, update badges, section-header
    /// underlines) so it stays meaningful rather than becoming wallpaper.
    static let auroraColors: [Color] = [
        Color(red: 0.93, green: 0.32, blue: 0.37),
        Color(red: 0.95, green: 0.58, blue: 0.28),
        Color(red: 0.96, green: 0.80, blue: 0.38),
        Color(red: 0.44, green: 0.78, blue: 0.55),
        Color(red: 0.38, green: 0.67, blue: 0.92),
        Color(red: 0.62, green: 0.52, blue: 0.87),
    ]

    /// Horizontal aurora gradient — the default orientation for fills
    /// (buttons, badges, underlines).
    static let auroraGradient = LinearGradient(
        colors: auroraColors,
        startPoint: .leading,
        endPoint: .trailing
    )

    /// A softened version of the aurora gradient for large fills (e.g. a
    /// full-width primary button) where the fully saturated stripe would
    /// be too loud — same hues, lower opacity, blended over the accent
    /// base color so it still reads as a solid, legible button.
    static var auroraButtonFill: LinearGradient {
        LinearGradient(
            colors: auroraColors.map { $0.opacity(0.9) },
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    // MARK: - Night surfaces

    /// The icon's deep blue-black night sky. Always layered under a
    /// material (never used as an opaque fill over content) so panels read
    /// as intentional "Bifrost navy" in dark mode while staying subtle —
    /// not muddy — in light mode.
    static let night = Color(red: 0.043, green: 0.055, blue: 0.145)

    // MARK: - Typography

    /// Rounded, prominent — used for screen/section titles so headings
    /// feel like part of Bifrost's identity rather than default system
    /// chrome. Body text intentionally stays on the regular system font
    /// for maximum readability in dense lists (mod names, README text).
    static func titleFont(_ size: CGFloat = 22, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func headingFont(_ size: CGFloat = 14, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    // MARK: - Metrics

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let card: CGFloat = 14
        static let row: CGFloat = 10
        static let icon: CGFloat = 12
        static let pill: CGFloat = 999
    }

    // MARK: - Motion

    /// The one animation curve used for state changes across the app
    /// (launch phases, toggles, badge appearance) — quick and settled,
    /// never bouncy or attention-grabbing.
    static let settle = Animation.easeInOut(duration: 0.22)
}

// MARK: - Card surface

/// A "Bifrost card": a material panel with a faint night-blue tint so it
/// reads as part of the app's identity in both light and dark appearance,
/// plus a hairline border. Used for grouped content in place of the
/// system's default `GroupBox` chrome.
private struct BifrostCardBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = Theme.Radius.card

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Theme.night.opacity(colorScheme == .dark ? 0.4 : 0.045))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 1)
                }
        }
    }
}

extension View {
    /// Wraps this view's existing padding/content in a Bifrost card
    /// surface. Callers should apply their own `.padding(...)` first.
    func bifrostCard(cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        modifier(BifrostCardBackground(cornerRadius: cornerRadius))
    }
}

// MARK: - Section header

/// A small rounded-title header with a thin aurora underline — the
/// section-header treatment used throughout the app in place of plain
/// `GroupBox`/`Section` titles.
struct SectionHeader: View {
    let title: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(Theme.headingFont(12))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(Theme.headingFont(13))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
        }
        .padding(.bottom, 2)
        .overlay(alignment: .bottomLeading) {
            Theme.auroraGradient
                .frame(width: 28, height: 2)
                .clipShape(Capsule())
                .offset(y: 4)
        }
    }
}

// MARK: - Capsule chip

/// A small pill-shaped label used for stats ("↓ 12K"), category tags,
/// keybinds ("⌨ H"), and dependency names — the compact, calm secondary
/// vocabulary that lets the aurora accent stay rare.
struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary
    var prominent: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
                .lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(prominent ? .white : tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            if prominent {
                Capsule().fill(Theme.auroraGradient)
            } else {
                Capsule().fill(tint.opacity(0.14))
            }
        }
    }
}

/// A gradient-filled chip specifically for "something needs your
/// attention" states (update available, active profile) — the aurora
/// accent applied to a badge rather than a full button.
struct AuroraBadge: View {
    let text: String
    var systemImage: String?

    var body: some View {
        Chip(text: text, systemImage: systemImage, prominent: true)
    }
}

// MARK: - Status pill card (Home's 2x2 grid)

/// One compact status check for the Home hero panel's 2x2 grid: an icon,
/// a title, and a one-line subtitle, tinted green or red by `ok`.
struct StatusPillCard: View {
    let title: String
    let ok: Bool
    let subtitle: String
    let systemImage: String

    private var tint: Color { ok ? .green : .red }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.16))
                Image(systemName: ok ? "checkmark" : "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: systemImage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .bifrostCard(cornerRadius: Theme.Radius.row)
    }
}

// MARK: - Button styles

/// Bifrost's primary action style: a full-width aurora-gradient fill with
/// bold rounded text — reserved for the single most important action on a
/// screen (Play Modded, Install, primary wizard actions).
struct AuroraButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var verticalPadding: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.headingFont(15))
            .foregroundStyle(.white)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(Theme.auroraButtonFill)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(Theme.settle, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == AuroraButtonStyle {
    static var aurora: AuroraButtonStyle { AuroraButtonStyle() }
}

/// A quiet secondary action style: plain text, no chrome beyond a faint
/// hover-independent background, for actions that should sit beside a
/// primary aurora button without competing with it (Play Vanilla).
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(isEnabled ? .primary : .secondary)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.10 : 0.05))
            }
            .opacity(isEnabled ? 1 : 0.5)
            .animation(Theme.settle, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
}

// MARK: - Flow layout

/// A simple left-to-right, top-to-bottom wrapping layout for chip/capsule
/// collections (category tags, dependency lists) whose count varies and
/// shouldn't be clipped or force a fixed column count the way
/// `LazyVGrid` would.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x + size.width > maxWidth, origin.x > 0 {
                origin.x = 0
                origin.y += rowHeight + spacing
                totalHeight = origin.y
                rowHeight = 0
            }
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalHeight = origin.y + rowHeight
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : origin.x, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var origin = CGPoint(x: bounds.minX, y: bounds.minY)
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x + size.width > bounds.maxX, origin.x > bounds.minX {
                origin.x = bounds.minX
                origin.y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: origin, proposal: ProposedViewSize(size))
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
