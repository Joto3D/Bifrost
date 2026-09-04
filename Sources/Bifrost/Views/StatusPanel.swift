import SwiftUI

/// Home tab content: shows the four setup prerequisites and, once wiring
/// lands in a later phase, the actual play buttons.
struct StatusPanel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 24) {
            GroupBox("Setup Status") {
                VStack(alignment: .leading, spacing: 14) {
                    StatusRow(
                        title: "Valheim found",
                        ok: appState.status.gameFound != nil,
                        subtitle: appState.status.gameFound?.path ?? "Could not locate Valheim via Steam"
                    )
                    Divider()
                    StatusRow(
                        title: "BepInEx installed",
                        ok: appState.status.bepinexInstalled,
                        subtitle: appState.status.bepinexInstalled
                            ? "Mod loader is present"
                            : "BepInEx not installed"
                    )
                    Divider()
                    StatusRow(
                        title: "Rosetta 2 available",
                        ok: appState.status.rosettaOK,
                        subtitle: appState.status.rosettaOK
                            ? "x86_64 translation works"
                            : "Rosetta 2 is not installed"
                    )
                    Divider()
                    StatusRow(
                        title: "Steam launch options configured",
                        ok: appState.status.steamConfigured,
                        subtitle: appState.status.steamConfigured
                            ? "Launch options route through Bifrost"
                            : "Steam launch options not set"
                    )
                }
                .padding(8)
            }

            Button {
                Task { await appState.refresh() }
            } label: {
                if appState.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(appState.isRefreshing)

            HStack(spacing: 16) {
                Button {
                    // Wired up in a later phase.
                } label: {
                    Label("Play Modded", systemImage: "shippingbox.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(true)
                .help("Coming in a later phase")

                Button {
                    // Wired up in a later phase.
                } label: {
                    Label("Play Vanilla", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .disabled(true)
                .help("Coming in a later phase")
            }
        }
        .padding(24)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await appState.refresh()
        }
    }
}

private struct StatusRow: View {
    let title: String
    let ok: Bool
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
                .font(.system(size: 18))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Spacer()
        }
    }
}
