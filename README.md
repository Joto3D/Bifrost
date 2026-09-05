# Bifrost (Windows)

A Windows port of [Bifrost](https://github.com/), the Valheim mod
launcher/manager. The reference implementation is a native macOS SwiftUI
app; this repo re-implements the same app shell and feature set (BepInEx
setup, Steam-integrated modded/vanilla launch, Thunderstore mod
browsing/install) for Windows using [Avalonia UI](https://avaloniaui.net/)
on .NET, with an MVVM architecture via
[CommunityToolkit.Mvvm](https://learn.microsoft.com/dotnet/communitytoolkit/mvvm/).

**Status: core services ported and wired to a functional UI.** Game
discovery, BepInEx install, Thunderstore mod management, profiles, and
Steam launch are implemented in `src/Bifrost.Core` and driven from four
working tabs (Home / Browse / Installed / Settings). Polish (styling,
richer progress UI, drag-free profile management) is a later phase.

## Layout

```
bifrost-windows.sln
src/
  Bifrost/         # Avalonia app: views, view models, app shell
  Bifrost.Core/    # platform-neutral class library:
                   #   Models/   InstalledManifest, Profile(sFile), ThunderstorePackage
                   #   Services/ GameLocator, VdfParser, DoorstopConfig,
                   #             ThunderstoreClient, BepInExInstaller, ModManager,
                   #             ProfileStore, Launcher, Diagnostics, SelfTest
scripts/
  publish-win.sh   # builds a self-contained win-x64 single-file Bifrost.exe
```

The four tabs (Home / Browse / Installed / Settings) mirror the macOS
app's tab layout:

- **Home** — setup status (game found, BepInEx installed, doorstop
  modded/vanilla state, Steam running), Play Modded / Play Vanilla, and
  the active profile picker.
- **Browse** — searchable/sortable Thunderstore package list, Install with
  a dependency-resolution confirmation step.
- **Installed** — manifest list with enable/disable, update, remove, and a
  profiles management dialog (create/duplicate/rename/delete).
- **Settings** — detected paths (Steam root, game directory, app data
  directory), refresh the Thunderstore index, open logs/plugins/app-data
  folders.

## What's ported from the macOS reference implementation

Ported 1:1 (same algorithms, Windows-appropriate I/O):
`ModManager` (resolve/install/uninstall/enable-disable/update, r2modman
payload-mapping heuristics, dependency resolution), `ProfileStore`
(apply/reconcile/sync/migration), `ThunderstoreClient` (index fetch with
`If-Modified-Since` conditional revalidation), `Diagnostics` (BepInEx log
classification).

Ported with a Windows-specific delta (see each type's doc comment for
details): `GameLocator` (registry-resolved Steam root instead of
`~/Library/Application Support/Steam`, `valheim.exe` instead of
`valheim.app`), `BepInExInstaller` (payload is `BepInEx/`, `winhttp.dll`,
`doorstop_config.ini`, `.doorstop_version` — no `doorstop_libs`, no unix
start scripts, no quarantine/chmod step), `Launcher` (the modded/vanilla
toggle flips `doorstop_config.ini`'s `[General] enabled` key instead of
Steam launch options + a wrapper script — Windows Valheim just needs
`winhttp.dll` sitting in the game directory).

Not ported (Windows doesn't need it): `SteamConfigurator` /
`SteamLaunchLogParser` / `SteamLogWatcher` / `VDF`'s splicing half / the
BepInEx config editor — no Steam launch-options editing happens on
Windows at all.

## Requirements to build

- .NET 10 SDK
- Works on macOS, Linux, or Windows — Avalonia is cross-platform, and
  publishing a Windows binary does **not** require building on Windows
  (see below).

## Building and running (on Mac or any dev machine)

```sh
dotnet build
dotnet run --project src/Bifrost
```

This opens the Avalonia app window locally, whatever platform you're on
(including macOS) — useful for iterating on the UI without a Windows
machine.

### Headless self-test

Mirrors the macOS app's `Bifrost --check` mode
(`Sources/Bifrost/DebugCheck.swift`): runs against temp fixtures (and,
where safe, real Thunderstore downloads) and prints PASS/FAIL per section,
then exits with a non-zero status on any failure — no window, no Windows
machine required. Every section is written to be safe on a non-Windows dev
machine: Steam root resolution is overridable via `BIFROST_STEAM_ROOT` or
a constructor parameter, every mutation happens under a temp directory,
and the manifest-shape check only ever *reads* the real macOS
`manifest.json`.

```sh
dotnet run --project src/Bifrost -- --check
```

Sections: setup status, VDF/ACF parsing (embedded fixtures + an
integration test against a fake Steam root), doorstop ini toggle
round-trip (byte-preserving both directions), Thunderstore index fetch +
304 revalidation, BepInEx installer (real download into a fake game dir,
verifying `winhttp.dll` lands and the unix-only payload is excluded), mod
manager end-to-end (real Thunderstore downloads: a simple mod, a
mod with a resolved dependency + the loader, enable/disable, uninstall,
update-detection), profile reconcile (migration, CRUD, the three apply
cases, manual-edit sync, delete-active guard), and manifest JSON shape
compatibility (parses a read-only copy of the real macOS
`~/Library/Application Support/Bifrost/manifest.json` to prove the two
apps' JSON shapes match).

## Publishing for Windows

Cross-compiles a self-contained, single-file `win-x64` executable — no
Windows workload or Windows machine required, even when run from macOS:

```sh
./scripts/publish-win.sh
```

Output lands at
`src/Bifrost/bin/Release/net10.0/win-x64/publish/Bifrost.exe`. The script
prints the exact output path and the resulting file size.

## Notes

- Targets `net10.0`.
- `manifest.json`/`profiles.json` use the exact same field names as the
  macOS app's `InstalledManifest.swift`/`Profile.swift` (camelCase,
  `activeProfileID` with capital ID, uppercase-hyphenated GUIDs matching
  Swift's `UUID().uuidString`), so a manifest or profile set could
  conceptually be shared across platforms later.
- `BifrostPaths.ResolveSteamRoot()` reads `HKCU\SOFTWARE\Valve\Steam` via
  `Microsoft.Win32.Registry` (guarded by `OperatingSystem.IsWindows()`),
  falling back to the two well-known Program Files locations; every
  service that needs it accepts an override for testing.
