import SwiftUI

/// Home's "Saga" stats card: a read-only viking-flavored summary built by
/// `SagaStats` from state the rest of the app already tracks (the installed
/// manifest) plus a few cheap read-only lookups of its own (the cached
/// Thunderstore index, the backups list, Steam's `localconfig.vdf`, and the
/// save directory). Degrades gracefully — via `SagaStats.flavorLines` — when
/// any of those sources is missing (fresh install, never launched through
/// Steam, no saves yet).
struct SagaCard: View {
    @Environment(AppState.self) private var appState
    @State private var thunderstoreClient = ThunderstoreClient()
    @State private var snapshot: SagaStats.Snapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionHeader(title: "Saga", systemImage: "text.book.closed")

            ForEach(displayedLines, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .bifrostCard(cornerRadius: Theme.Radius.row)
        .task(id: appState.manifest) {
            await loadSnapshot()
        }
    }

    /// The card stays compact by showing at most the top 3 flavor lines
    /// (`SagaStats.flavorLines` already orders them by priority); the full
    /// snapshot is still computed in full for `--check` to verify.
    private var displayedLines: [String] {
        Array(SagaStats.flavorLines(for: snapshot ?? .empty).prefix(3))
    }

    private func loadSnapshot() async {
        let index = (try? await thunderstoreClient.fetchIndex(force: false)) ?? []
        let backups = await SaveBackup().list()
        let localConfigText = SteamConfigurator.realLocalConfigURL().flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        snapshot = SagaStats.snapshot(
            manifest: appState.manifest,
            index: index,
            backups: backups,
            saveDir: SaveBackup.defaultSaveDir,
            localConfigText: localConfigText
        )
    }
}
