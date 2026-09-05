import SwiftUI

/// A dismissible amber banner shown above `MainWindow`'s tabs when
/// `AppState.gameUpdateCheck` reports Valheim's Steam build changed since
/// Bifrost last checked (see `GameUpdateWatcher`) — right where the player
/// will see it before clicking Play, since a new build can silently break
/// mods, and a Steam "verify integrity of game files" pass can strip
/// BepInEx's own files back out.
struct GameUpdateBanner: View {
    @Environment(AppState.self) private var appState
    @Binding var isDismissed: Bool
    /// Switches `MainWindow`'s own tab selection to Installed and asks
    /// `InstalledModsView` to re-check for updates. `MainWindow` owns the
    /// tab state, so this is threaded in as a closure rather than this view
    /// reaching for it directly.
    let onCheckModUpdates: () -> Void

    @State private var isVerifying = false
    @State private var verifyStatusLine: String?

    var body: some View {
        if case .updated(let previousBuildID, let currentBuildID) = appState.gameUpdateCheck, !isDismissed {
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.system(size: 16, weight: .semibold))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Valheim updated (build \(previousBuildID) \u{2192} \(currentBuildID))")
                        .font(Theme.headingFont(13))

                    Text("Mods may be broken until updated. BepInEx may need reinstalling if Steam verified game files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let verifyStatusLine {
                        Text(verifyStatusLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: Theme.Spacing.s) {
                        Button {
                            Task { await verifyBepInEx() }
                        } label: {
                            if isVerifying {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Verify BepInEx")
                            }
                        }
                        .disabled(isVerifying || appState.status.gameFound == nil)

                        Button("Check Mod Updates") {
                            onCheckModUpdates()
                        }
                        .disabled(isVerifying)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)

                Button {
                    isDismissed = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(Theme.Spacing.m)
            .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .strokeBorder(Color.yellow.opacity(0.4), lineWidth: 1)
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.top, Theme.Spacing.s)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(Theme.settle, value: isDismissed)
        }
    }

    /// Runs `BepInExInstaller.status`; if the pack files or the launch
    /// wrapper are missing, treats that as "BepInEx needs reinstalling" —
    /// exactly the scenario this banner warns about after a Steam
    /// file-verify — and repairs it with a normal `install`, which never
    /// touches `BepInEx/plugins`/`config`, so the user's mods and settings
    /// survive. Records the (re)installed version back into the manifest,
    /// same as any other loader install, then refreshes `AppState` so the
    /// Home tab's status grid and this banner's own state catch up.
    private func verifyBepInEx() async {
        guard let gameDir = appState.status.gameFound else { return }
        isVerifying = true
        defer { isVerifying = false }

        let installer = BepInExInstaller()
        let launchDir = BepInExInstaller.defaultLaunchDir
        let status = await installer.status(gameDir: gameDir, launchDir: launchDir)

        guard !status.packFilesPresent || !status.wrapperInstalled else {
            verifyStatusLine = "BepInEx looks intact — nothing to repair."
            return
        }

        verifyStatusLine = "Repairing BepInEx…"
        do {
            let outcome = try await installer.install(
                gameDir: gameDir,
                launchDir: launchDir,
                manifestVersion: appState.manifest.loader?.version
            )
            try? await appState.modManager.setLoaderVersion(outcome.versionNumber)
            verifyStatusLine = "BepInEx repaired (version \(outcome.versionNumber))."
            await appState.refresh()
        } catch {
            verifyStatusLine = "Couldn't repair BepInEx: \(error.localizedDescription)"
        }
    }
}
