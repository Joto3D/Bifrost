import SwiftUI
import AppKit

/// Preference key backing "Show menu bar icon" in Settings (see
/// `SettingsView`) and the `MenuBarExtra`'s `isInserted` binding in
/// `BifrostApp`. Defaults to on. Its own tiny namespace rather than living
/// on `Launcher`/`AppState` since it's specifically about the menu bar
/// item's presence, not launch behavior or app state.
enum MenuBarPreference {
    static let showIconDefaultsKey = "showMenuBarIcon"
}

/// Content of Bifrost's `MenuBarExtra` — a quick-launch menu that works
/// without raising the main window: Play Modded/Vanilla (through the same
/// `Launcher` the Home tab uses), a profile-switch submenu, and the usual
/// Open/Quit pair.
///
/// Switching profiles from here follows the same missing-mods guard the
/// Home tab's picker does (see `StatusPanel.performProfileSwitch`), except
/// a menu has nowhere to show a confirmation dialog for the result — so
/// rather than silently installing mods the user never asked for from a
/// background menu click, a switch that would leave mods missing just
/// raises the main window instead, where the existing "Install Missing"
/// flow can take over.
struct BifrostMenuBarContent: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Play Modded") {
            Task { _ = try? await Launcher.play(modded: true) }
        }
        .disabled(!appState.status.readyToPlay)

        Button("Play Vanilla") {
            Task { _ = try? await Launcher.play(modded: false) }
        }
        .disabled(!appState.status.readyToPlay)

        Divider()

        Menu("Profile") {
            if appState.profiles.profiles.isEmpty {
                Text("No profiles yet")
            } else {
                ForEach(appState.profiles.profiles.sorted(by: { $0.name < $1.name })) { profile in
                    Button {
                        Task { await switchProfile(to: profile.id) }
                    } label: {
                        if profile.id == appState.profiles.activeProfileID {
                            Label(profile.name, systemImage: "checkmark")
                        } else {
                            Text(profile.name)
                        }
                    }
                }
            }
        }
        .disabled(appState.profiles.profiles.isEmpty || appState.status.gameFound == nil)

        Divider()

        Button("Open Bifrost") {
            activateMainWindow()
        }

        Divider()

        Button("Quit Bifrost") {
            NSApplication.shared.terminate(nil)
        }
    }

    /// Applies `profileID` via the same `AppState.applyProfile` the Home tab
    /// uses. If it reports mods the profile wants that aren't installed
    /// yet, this never installs them on its own initiative from a
    /// background menu click — it raises the main window instead, so the
    /// user sees exactly what's missing through the normal confirmation
    /// flow before anything gets installed.
    private func switchProfile(to profileID: UUID) async {
        guard let gameDir = appState.status.gameFound else { return }
        do {
            let result = try await appState.applyProfile(id: profileID, gameDir: gameDir)
            if !result.missing.isEmpty {
                activateMainWindow()
            }
        } catch {
            appState.reportError("Couldn't switch profile", error.localizedDescription)
            activateMainWindow()
        }
    }

    /// Brings Bifrost's main window to the front, reopening it first if it
    /// had been closed.
    private func activateMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }
}
