import SwiftUI
import Observation

/// Bifrost's small design system: shared color, gradient, typography, and
/// spacing constants, plus a handful of reusable view helpers, so every
/// screen reads as one consistent identity instead of each view rolling
/// its own ad-hoc styling.
///
/// Color is the one axis that's user-selectable (see `ThemePalette` and
/// `ThemeStore` below) — fonts, spacing, radii, and motion stay global
/// across every palette.
///
/// This file is presentation-only — nothing here reads or mutates any
/// model, service, or `AppState`. Behavior lives entirely in the views that
/// consume these tokens.
enum Theme {
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

// MARK: - Theme palette

/// One selectable Bifrost color identity: an accent gradient (the "one
/// splash of color" used sparingly for primary actions, badges, progress,
/// and underlines) plus a base surface tone layered under card materials.
/// Fonts, spacing, radii, and motion are deliberately *not* part of this —
/// they're shared across every palette (see `Theme`).
struct ThemePalette: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String

    /// The accent gradient's stops, left-to-right. A single-color palette
    /// (see `.plain`) is expressed as a one-element array — a `LinearGradient`
    /// with one stop renders as a plain solid fill, so every consumer below
    /// (buttons, badges, underlines, progress dots) can stay a gradient type
    /// without a "does this palette have a gradient?" branch anywhere.
    let accentColors: [Color]

    /// The deep base/surface tone layered at low opacity under card
    /// materials and icon roundels (Bifrost's original "night" blue). Always
    /// used under a material, never as an opaque fill, so it reads as
    /// intentional in dark mode while staying subtle in light mode.
    let surface: Color

    /// A single calmer accent that complements the gradient — used where the
    /// full multi-stop sweep would be too busy for a small shape (the theme
    /// swatch's border in Settings' Appearance picker).
    let secondaryAccent: Color

    /// A flat wash used behind palette-flavored surfaces that want a tinted
    /// background rather than the full gradient sweep (the selected-row
    /// highlight in Settings' Appearance picker).
    let badgeTint: Color

    /// The signature accent as a left-to-right gradient — the default
    /// orientation for fills (buttons, badges, underlines, progress dots).
    var accentGradient: LinearGradient {
        LinearGradient(colors: accentColors, startPoint: .leading, endPoint: .trailing)
    }

    /// A softened version of the accent gradient for large fills (e.g. a
    /// full-width primary button) where the fully saturated stripe would be
    /// too loud — same hues, lower opacity, blended over the button chrome
    /// so it still reads as a solid, legible button.
    var accentButtonFill: LinearGradient {
        LinearGradient(colors: accentColors.map { $0.opacity(0.9) }, startPoint: .leading, endPoint: .trailing)
    }
}

extension ThemePalette {
    /// The original "deep night sky + rainbow bridge" identity (matching
    /// `Resources/icon.png`) — Bifrost's default palette. Every color here
    /// is byte-identical to the constants this type replaced, so selecting
    /// "Bifrost" reproduces the app's original look exactly.
    static let bifrost = ThemePalette(
        id: "bifrost",
        displayName: "Bifrost",
        accentColors: [
            Color(red: 0.93, green: 0.32, blue: 0.37),
            Color(red: 0.95, green: 0.58, blue: 0.28),
            Color(red: 0.96, green: 0.80, blue: 0.38),
            Color(red: 0.44, green: 0.78, blue: 0.55),
            Color(red: 0.38, green: 0.67, blue: 0.92),
            Color(red: 0.62, green: 0.52, blue: 0.87),
        ],
        surface: Color(red: 0.043, green: 0.055, blue: 0.145),
        secondaryAccent: Color(red: 0.38, green: 0.67, blue: 0.92),
        badgeTint: Color(red: 0.62, green: 0.52, blue: 0.87)
    )

    /// Meadows and viking gold — deep forest-green surfaces under a
    /// gold-to-moss accent sweep.
    static let midgard = ThemePalette(
        id: "midgard",
        displayName: "Midgard",
        accentColors: [
            Color(red: 0.85, green: 0.70, blue: 0.22),
            Color(red: 0.72, green: 0.66, blue: 0.26),
            Color(red: 0.56, green: 0.60, blue: 0.30),
            Color(red: 0.42, green: 0.56, blue: 0.32),
            Color(red: 0.30, green: 0.48, blue: 0.33),
        ],
        surface: Color(red: 0.035, green: 0.09, blue: 0.05),
        secondaryAccent: Color(red: 0.45, green: 0.58, blue: 0.36),
        badgeTint: Color(red: 0.85, green: 0.70, blue: 0.22)
    )

    /// Deep red-to-amber embers over a near-black charcoal surface.
    static let ashlands = ThemePalette(
        id: "ashlands",
        displayName: "Ashlands",
        accentColors: [
            Color(red: 0.55, green: 0.08, blue: 0.10),
            Color(red: 0.80, green: 0.22, blue: 0.10),
            Color(red: 0.93, green: 0.45, blue: 0.12),
            Color(red: 0.96, green: 0.68, blue: 0.25),
        ],
        surface: Color(red: 0.06, green: 0.035, blue: 0.03),
        secondaryAccent: Color(red: 0.82, green: 0.36, blue: 0.15),
        badgeTint: Color(red: 0.96, green: 0.68, blue: 0.25)
    )

    /// Dusky indigo surfaces under a teal-to-violet mist accent.
    static let mistlands = ThemePalette(
        id: "mistlands",
        displayName: "Mistlands",
        accentColors: [
            Color(red: 0.20, green: 0.55, blue: 0.55),
            Color(red: 0.30, green: 0.50, blue: 0.63),
            Color(red: 0.45, green: 0.46, blue: 0.71),
            Color(red: 0.58, green: 0.42, blue: 0.75),
        ],
        surface: Color(red: 0.09, green: 0.07, blue: 0.16),
        secondaryAccent: Color(red: 0.42, green: 0.48, blue: 0.68),
        badgeTint: Color(red: 0.56, green: 0.44, blue: 0.73)
    )

    /// Steel-blue ice surfaces under a white-to-pale-blue accent.
    static let deepNorth = ThemePalette(
        id: "deep-north",
        displayName: "Deep North",
        accentColors: [
            Color(red: 0.85, green: 0.93, blue: 0.97),
            Color(red: 0.55, green: 0.82, blue: 0.93),
            Color(red: 0.35, green: 0.62, blue: 0.85),
            Color(red: 0.55, green: 0.70, blue: 0.88),
        ],
        surface: Color(red: 0.07, green: 0.10, blue: 0.15),
        secondaryAccent: Color(red: 0.45, green: 0.70, blue: 0.88),
        badgeTint: Color(red: 0.55, green: 0.82, blue: 0.93)
    )

    /// Minimal: the system accent color standing in for the gradient (a
    /// one-stop "gradient" renders as a plain solid fill) over neutral,
    /// near-system surfaces — for people who want it quiet.
    static let plain = ThemePalette(
        id: "plain",
        displayName: "Plain",
        accentColors: [Color.accentColor],
        surface: Color(white: 0.08),
        secondaryAccent: Color.secondary,
        badgeTint: Color.accentColor
    )

    /// Every selectable palette, in the order shown by Settings' theme
    /// picker. `.bifrost` stays first as the default.
    static let all: [ThemePalette] = [.bifrost, .midgard, .ashlands, .mistlands, .deepNorth, .plain]
}

// MARK: - Theme store

/// Owns the currently-selected `ThemePalette`, persisted across launches,
/// and injected into the view hierarchy via `.environment(_:)` so every
/// screen reads `themeStore.current` instead of a global constant — that's
/// what makes picking a theme in Settings update every screen live without
/// threading a palette through every view's `init`.
@MainActor
@Observable
final class ThemeStore {
    private static let storageKey = "bifrost.theme"

    /// Backed by `UserDefaults` under `"bifrost.theme"` (the same key an
    /// `@AppStorage("bifrost.theme")` would use) so the selection survives
    /// relaunches. Kept as a plain observed property — rather than
    /// `@AppStorage` directly — because `@AppStorage`'s own storage
    /// mechanism doesn't compose with `@Observable`'s; this achieves the
    /// same persistence by hand.
    var current: ThemePalette {
        didSet {
            guard current.id != oldValue.id else { return }
            UserDefaults.standard.set(current.id, forKey: Self.storageKey)
        }
    }

    init() {
        let storedID = UserDefaults.standard.string(forKey: Self.storageKey)
        current = ThemePalette.all.first { $0.id == storedID } ?? .bifrost
    }
}

// MARK: - Card surface

/// A "Bifrost card": a material panel with a faint tint (from the current
/// theme's `surface` color) so it reads as part of the app's identity in
/// both light and dark appearance, plus a hairline border. Used for grouped
/// content in place of the system's default `GroupBox` chrome.
private struct BifrostCardBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ThemeStore.self) private var themeStore
    var cornerRadius: CGFloat = Theme.Radius.card

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(themeStore.current.surface.opacity(colorScheme == .dark ? 0.4 : 0.045))
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

/// A small rounded-title header with a thin accent underline — the
/// section-header treatment used throughout the app in place of plain
/// `GroupBox`/`Section` titles.
struct SectionHeader: View {
    @Environment(ThemeStore.self) private var themeStore
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
            themeStore.current.accentGradient
                .frame(width: 28, height: 2)
                .clipShape(Capsule())
                .offset(y: 4)
        }
    }
}

// MARK: - Capsule chip

/// A small pill-shaped label used for stats ("↓ 12K"), category tags,
/// keybinds ("⌨ H"), and dependency names — the compact, calm secondary
/// vocabulary that lets the accent stay rare.
struct Chip: View {
    @Environment(ThemeStore.self) private var themeStore
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
                Capsule().fill(themeStore.current.accentGradient)
            } else {
                Capsule().fill(tint.opacity(0.14))
            }
        }
    }
}

/// A gradient-filled chip specifically for "something needs your
/// attention" states (update available, active profile) — the current
/// theme's accent applied to a badge rather than a full button.
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

/// Bifrost's primary action style: a full-width accent-gradient fill with
/// bold rounded text — reserved for the single most important action on a
/// screen (Play Modded, Install, primary wizard actions).
struct AuroraButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(ThemeStore.self) private var themeStore
    var verticalPadding: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.headingFont(15))
            .foregroundStyle(.white)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(themeStore.current.accentButtonFill)
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
