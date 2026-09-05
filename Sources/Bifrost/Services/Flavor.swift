import Foundation

/// Purely decorative launch flavor text: a curated set of short viking-themed
/// quips shown as a secondary caption *underneath* the real launch status
/// line in `StatusPanel` while a launch is in progress. Never replaces the
/// real status — Bifrost's actual phase description always stays primary —
/// this is just a bit of personality alongside it.
enum Flavor {
    /// ~25 short launch quips. Every entry is unique (see `DebugCheck`'s
    /// "fun" section, which asserts this).
    static let quips: [String] = [
        "Sharpening the axe…",
        "Rowing the karve ashore…",
        "Bribing Hugin with breadcrumbs…",
        "Waking the Greydwarfs gently…",
        "Polishing Mjölnir replicas…",
        "Counting runestones twice…",
        "Braiding the beard for battle…",
        "Asking Odin for a tailwind…",
        "Feeding the boar a snack…",
        "Tuning the longship's oars…",
        "Checking the mead reserves…",
        "Whittling a spare arrow…",
        "Reinforcing the palisade…",
        "Consulting the sacrificial stones…",
        "Untangling the fishing net…",
        "Warming up the campfire…",
        "Negotiating with a troll…",
        "Stitching the linen cape…",
        "Rolling the dice with Yggdrasil…",
        "Greasing the portal runes…",
        "Herding stray lox…",
        "Sweeping the longhouse floor…",
        "Waxing the shield rim…",
        "Listening for Freyr's blessing…",
        "Loading the ballista, gently…",
    ]

    /// Deterministically picks one quip for `seed` — the caller derives
    /// `seed` once per launch (e.g. from the launch's start timestamp) so
    /// every phase update during that same launch shows the same line
    /// instead of flickering between quips on every status change, while a
    /// fresh launch gets a fresh roll. Uses a tiny seedable
    /// `RandomNumberGenerator` rather than `Array.randomElement()`'s default
    /// (unseedable) system RNG.
    static func quip(seed: Int) -> String {
        var generator = SeededGenerator(seed: seed)
        return quips.randomElement(using: &generator) ?? quips[0]
    }
}

/// A minimal seedable xorshift64* generator. Swift's standard library has no
/// seedable `RandomNumberGenerator` of its own, and `Flavor.quip` needs
/// reproducible output for a given seed within one launch.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: Int) {
        // xorshift64* requires a non-zero state; folding in a fixed odd
        // constant keeps a seed of exactly 0 from producing a permanently-
        // zero (and therefore non-random) generator.
        let folded = UInt64(bitPattern: Int64(seed)) ^ 0x9E37_79B9_7F4A_7C15
        state = folded == 0 ? 0x9E37_79B9_7F4A_7C15 : folded
    }

    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2685821657736338717
    }
}
