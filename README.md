# Bifrost (Windows)

A Windows port of Bifrost, the Valheim mod launcher/manager whose
reference implementation is a native macOS SwiftUI app
(`../valheim-mod-launcher`). This repo re-implements the same app shell,
visual identity, and feature set (BepInEx setup, Steam-integrated
modded/vanilla launch, Thunderstore mod browsing/install, profiles,
theming) for Windows using [Avalonia UI](https://avaloniaui.net/) on
.NET, with an MVVM architecture via
[CommunityToolkit.Mvvm](https://learn.microsoft.com/dotnet/communitytoolkit/mvvm/).

**Status: feature-complete port, built and verified entirely on macOS —
not yet run on a real Windows machine.** Every service, the self-test
suite, and the packaged `.exe` build/run without issue here, and Avalonia
+ .NET's cross-compilation story is solid, but there is no substitute for
someone actually double-clicking `Bifrost.exe` on Windows once. See
[Known caveat](#known-caveat-untested-on-real-windows) below — that's the
one thing a Windows tester should check first.

## Layout

```
bifrost-windows.sln
src/
  Bifrost/           # Avalonia app: views, view models, theming, app shell
    Theming/          #   ThemePalette (6 palettes) + ThemeStore (persisted, live-applied)
    Services/         #   IconCache / IconLoader (async Thunderstore icon loading+caching)
    Converters/        #   small XAML value converters for status pills/badges
  Bifrost.Core/      # platform-neutral class library:
                     #   Models/   InstalledManifest, Profile(sFile), ThunderstorePackage
                     #   Services/ GameLocator, VdfParser, DoorstopConfig,
                     #             ThunderstoreClient, BepInExInstaller, ModManager,
                     #             ProfileStore, Launcher, Diagnostics, SelfTest
scripts/
  publish-win.sh     # builds a self-contained win-x64 single-file Bifrost.exe
  package-win.sh     # publish-win.sh + zips Bifrost.exe with a friends'
                      # README into dist/Bifrost-win-x64.zip
  FRIENDS-README.txt  # plain-English instructions bundled into that zip
```

The four tabs (Home / Browse / Installed / Settings) mirror the macOS
app's tab layout:

- **Home** — a launcher hero: title row, a 2x2 setup-status grid (game
  found, BepInEx installed, launch mode, Steam running), a first-run
  banner that walks through fixing a red status inline, the active
  profile picker, and the big gradient **Play Modded** / quiet **Play
  Vanilla** buttons.
- **Browse** — a searchable/sortable Thunderstore package list as cards
  (56px async-loaded, disk-cached icon; download/rating/updated stat
  chips; category capsules), with an Install flow that confirms a
  dependency-resolution plan before touching disk.
- **Installed** — manifest rows (icon, keybind chips parsed from each
  mod's BepInEx config, an accent "Update" badge) with enable/disable,
  update, remove, and a profiles management dialog
  (create/duplicate/rename/delete).
- **Settings** — detected paths (Steam root, game directory, app data
  directory), the **Appearance** theme picker (six palettes, applied
  live), refresh the Thunderstore index, open logs/plugins/app-data
  folders.

## Theming

`src/Bifrost/Theming/ThemePalette.cs` ports the macOS app's
`ThemePalette` system (`Views/Theme.swift`) byte-for-byte: the same six
named palettes — **Bifrost** (night-blue + aurora accent gradient, the
default), **Midgard**, **Ashlands**, **Mistlands**, **Deep North**, and
**Plain** — each an accent gradient plus a surface tone, secondary
accent, and badge tint. `Theming/ThemeStore.cs` is the Avalonia
counterpart of the macOS `ThemeStore`: it persists the chosen palette to
`%AppData%\Bifrost\theme.json` and applies it to the running
`Application` as a set of `DynamicResource` brushes
(`BifrostAccentGradientBrush`, `BifrostCardBackgroundBrush`,
`BifrostSidebarBrush`, etc.), recomputed against
`Application.ActualThemeVariant` so the same palette looks intentional
under both Fluent light and dark — not just "the dark colors forced onto
a light window." Switching a palette in Settings → Appearance updates
every open view immediately, live, with no restart.

## What's ported from the macOS reference implementation

Ported 1:1 (same algorithms, Windows-appropriate I/O):
`ModManager` (resolve/install/uninstall/enable-disable/update, r2modman
payload-mapping heuristics, dependency resolution), `ProfileStore`
(apply/reconcile/sync/migration), `ThunderstoreClient` (index fetch with
`If-Modified-Since` conditional revalidation), `Diagnostics` (BepInEx log
classification), `ThemePalette`/`ThemeStore` (see above).

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
`SteamLaunchLogParser` / `SteamLogWatcher` / `VDF`'s splicing half — no
Steam launch-options editing happens on Windows at all. The BepInEx
config editor (arbitrary `.cfg` key editing) exists in `Bifrost.Core` and
is exercised by `--check`, but isn't wired into the Windows UI yet — the
Installed tab shows each mod's parsed keybinds as read-only chips.

## Requirements to build

- .NET 10 SDK
- Works on macOS, Linux, or Windows — Avalonia is cross-platform, and
  publishing a Windows binary does **not** require building on Windows
  (see below). This entire project — every line of it — was written,
  built, and verified on macOS.

## Building and running (on Mac or any dev machine)

```sh
dotnet build
dotnet run --project src/Bifrost
```

This opens the Avalonia app window locally, whatever platform you're on
(including macOS) — useful for iterating on the UI without a Windows
machine. `dotnet build` produces zero warnings.

### Headless self-test

Mirrors the macOS app's `Bifrost --check` mode
(`Sources/Bifrost/DebugCheck.swift`): runs against temp fixtures (and,
where safe, real Thunderstore downloads) and prints PASS/FAIL per
section, then exits with a non-zero status on any failure — no window
required. **This also runs on a real Windows machine**, via
`Bifrost.exe --check` (see [Publishing](#publishing-for-windows) below) —
every section is written to skip gracefully rather than fail when a
Mac-only fixture source isn't present:

- The manifest-JSON-shape-compatibility section only ever *reads* the
  real macOS `manifest.json`; on Windows (or any machine without one) it
  prints `SKIPPED: no real macOS manifest.json found at ...` and moves
  on.
- The config-editor round-trip sweep and association-heuristic checks
  read this developer's real Valheim `BepInEx/config` directory
  (overridable via `BIFROST_CHECK_REAL_VALHEIM_CONFIG_DIR`); on a machine
  without that directory they print `SKIPPED: no real .cfg files found
  at ...` instead of failing.
- Steam root resolution is overridable via `BIFROST_STEAM_ROOT` or a
  constructor parameter, and every mutation happens under a temp
  directory — so the suite is safe to run on a fresh Windows install with
  no Steam/Valheim yet, or on this Mac dev machine, identically.

```sh
dotnet run --project src/Bifrost -- --check
```

On Windows, run the same check against the published exe:

```
Bifrost.exe --check
```

Sections: setup status, VDF/ACF parsing (embedded fixtures + an
integration test against a fake Steam root), doorstop ini toggle
round-trip (byte-preserving both directions), Thunderstore index fetch +
304 revalidation, BepInEx installer (real download into a fake game dir,
verifying `winhttp.dll` lands and the unix-only payload is excluded), mod
manager end-to-end (real Thunderstore downloads: a simple mod, a
mod with a resolved dependency + the loader, enable/disable, uninstall,
update-detection), profile reconcile (migration, CRUD, the three apply
cases, manual-edit sync, delete-active guard), manifest JSON shape
compatibility (see above — skips on Windows), and the config editor
(parser/writer round-trip, keyed apply, README fetch — real-file sections
skip on Windows).

## Publishing for Windows

Cross-compiles a self-contained, single-file `win-x64` executable — no
Windows workload or Windows machine required, even when run from macOS:

```sh
./scripts/publish-win.sh
```

Output lands at
`src/Bifrost/bin/Release/net10.0/win-x64/publish/Bifrost.exe`. The script
prints the exact output path and the resulting file size (currently
~100 MB — a self-contained .NET app bundles its own runtime).

## Packaging for non-technical friends

```sh
./scripts/package-win.sh
```

Runs `publish-win.sh`, then zips `Bifrost.exe` together with a
plain-English `README - READ ME FIRST.txt` (`scripts/FRIENDS-README.txt`
— what Bifrost is, how to get past the unsigned-exe SmartScreen warning,
first steps in the app, where to get help) into
`dist/Bifrost-win-x64.zip` (currently ~43 MB after zip compression). Hand
that one zip to a friend: unzip anywhere, double-click `Bifrost.exe`,
done.

### First-run experience in the app

If Valheim isn't found, or is found but BepInEx isn't installed, Home
shows a banner explaining what's missing and (once Valheim is found) an
**Install BepInEx** button that runs the same installer the Settings/full
setup path would — no separate wizard UI, just the one screen someone
actually looks at first.

## Version

`1.0.0` (`src/Bifrost/Bifrost.csproj`: `AssemblyVersion`, `FileVersion`,
`Version`, `InformationalVersion`).

## Known caveat: untested on real Windows

Every check in this repo — build, `--check`, the packaged `.exe`, the
window icon — has been verified on macOS via cross-compilation, and
Avalonia + .NET's Windows target is mature. But nothing here has actually
run on a Windows machine yet. If you're the first person to try it on
real Windows:

1. Confirm `Bifrost.exe` launches past the SmartScreen warning (see
   `scripts/FRIENDS-README.txt` for the exact "More info → Run anyway"
   steps).
2. Run `Bifrost.exe --check` from a command prompt in the unzipped
   folder and confirm `== All checks PASSED ==` (a few sections will
   print `SKIPPED` — that's expected, see above).
3. Confirm Steam root/game detection actually finds a real Valheim
   install (this exercises the registry-read path in
   `WindowsRegistry.cs`, which has no macOS equivalent to test against).
4. Confirm BepInEx installs and Valheim actually launches modded — the
   doorstop toggle and Steam `rungameid` launch have only been verified
   by reading Valheim's own Windows-side BepInEx/doorstop docs, not by
   watching Valheim actually load a mod.

Report anything that doesn't match this README back to Joshua.

## Notes

- Targets `net10.0`.
- `manifest.json`/`profiles.json` use the exact same field names as the
  macOS app's `InstalledManifest.swift`/`Profile.swift` (camelCase,
  `activeProfileID` with capital ID, uppercase-hyphenated GUIDs matching
  Swift's `UUID().uuidString`), so a manifest or profile set could
  conceptually be shared across platforms later. `theme.json` (this
  port's own addition — the macOS app persists its theme choice via
  `UserDefaults` instead) is not shared with the macOS app.
- `BifrostPaths.ResolveSteamRoot()` reads `HKCU\SOFTWARE\Valve\Steam` via
  `Microsoft.Win32.Registry` (guarded by `OperatingSystem.IsWindows()`),
  falling back to the two well-known Program Files locations; every
  service that needs it accepts an override for testing.
