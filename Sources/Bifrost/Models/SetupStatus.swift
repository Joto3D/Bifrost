import Foundation

/// Snapshot of everything Bifrost needs to verify before it can hand off a
/// modded launch to Steam.
struct SetupStatus: Sendable, Equatable {
    var gameFound: URL?
    var bepinexInstalled: Bool
    var rosettaOK: Bool
    var steamConfigured: Bool

    static let unknown = SetupStatus(
        gameFound: nil,
        bepinexInstalled: false,
        rosettaOK: false,
        steamConfigured: false
    )

    /// True once every prerequisite is satisfied and it's safe to offer a
    /// modded launch.
    var readyToPlay: Bool {
        gameFound != nil && bepinexInstalled && rosettaOK && steamConfigured
    }
}
