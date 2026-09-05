# Bifrost (Windows)

A Windows port of Bifrost, the Valheim mod launcher/manager whose
reference implementation is a native macOS SwiftUI app
(`../valheim-mod-launcher`). This repo re-implements the same app shell,
visual identity, and feature set (BepInEx setup, Steam-integrated
modded/vanilla launch, Thunderstore mod browsing/install, profiles,
theming) for Windows using [Avalonia UI](https://avaloniaui.net/) on
.NET, with an MVVM architecture via
[CommunityToolkit.Mvvm](https://learn.microsoft.com/dotnet/communitytoolkit/mvvm/).

**Status: feature-complete port (parity rounds A + B), built and verified
entirely on macOS — not yet run on a real Windows machine.** Every
service, the self-test suite, and the packaged `.exe` build/run without
issue here, and Avalonia + .NET's cross-compilation story is solid, but
there is no substitute for someone actually double-clicking `Bifrost.exe`
on Windows once. See
[Known caveat](#known-caveat-untested-on-real-windows) below — that's the
one thing a Windows tester should check first.

Parity round A added: install-from-file (drag a `.zip`/`.dll` straight
onto the window), save backups with retention + restore, Steam
build-update detection, "Update All", a tray icon, and silent-Steam
launch. Parity round B (this round) added: **Nexus Mods** integration
(`nxm://` link handling, API key storage, update checks), **multiplayer
safety** (mod risk classification, a guided "Join a Server" flow),
**profile sharing** (Bifrost's own share codes/files plus r2modman
interop), and a **fun round** (runestone tips, saga stats, launch quips,
Surprise Me, a subtle post-launch celebration) — see
[Parity round B](#parity-round-b-nexus-mods-multiplayer-safety-profile-sharing-fun-round)
below for the full rundown.

## Layout

```
bifrost-windows.sln
src/
  Bifrost/           # Avalonia app: views, view models, theming, app shell
    Theming/          #   ThemePalette (6 palettes) + ThemeStore (persisted, live-applied)
    Services/         #   IconCache / IconLoader (async Thunderstore icon loading+caching)
    Converters/        #   small XAML value converters for status pills/badges
  Bifrost.Core/      # platform-neutral class library:
                     #   Models/   InstalledManifest, Profile(sFile), ThunderstorePackage, NxmLink
                     #   Services/ GameLocator, VdfParser, DoorstopConfig,
                     #             ThunderstoreClient, BepInExInstaller, ModManager,
                     #             ProfileStore, Launcher, Diagnostics, SelfTest,
                     #             NexusClient, WindowsCredentials, NxmProtocolRegistrar,
                     #             SingleInstance, ModClassifier, ServerJoinPlanner,
                     #             ProfileShare, Flavor, RunestoneTips, SagaStats,
                     #             SurpriseMe, WindowsAccessibility
scripts/
  publish-win.sh     # builds a self-contained win-x64 single-file Bifrost.exe
  package-win.sh     # publish-win.sh + zips Bifrost.exe with a friends'
                      # README into dist/Bifrost-win-x64.zip
  FRIENDS-README.txt  # plain-English instructions bundled into that zip
```

The four tabs (Home / Browse / Installed / Settings) mirror the macOS
app's tab layout:

- **Home** — a launcher hero: title row, a runestone tip card (rotating
  practical tips + Valheim lore), a 2x2 setup-status grid (game found,
  BepInEx installed, launch mode, Steam running), a first-run banner that
  walks through fixing a red status inline, the active profile picker
  (with a "Back to my profile" hint when you're on a guest profile), a
  Saga stats card (playtime, worlds/heroes, mods by risk class, backup
  count), and the big gradient **Play Modded** / quiet **Play Vanilla** /
  **Join a Server…** buttons — with a decorative launch quip while
  launching and a subtle celebration pulse once BepInEx confirms plugins
  loaded.
- **Browse** — a searchable/sortable Thunderstore package list as cards
  (56px async-loaded, disk-cached icon; download/rating/updated stat
  chips; category capsules), a **Surprise Me** dice button that opens a
  random well-rated, not-yet-installed mod, and an Install flow that
  confirms a dependency-resolution plan before touching disk.
- **Installed** — manifest rows (icon, keybind chips parsed from each
  mod's BepInEx config, an accent "Update" badge, a "local"/"nexus"
  source chip, and a colored multiplayer-risk badge) with enable/disable,
  update, remove, install-from-file, Update All, and a profiles
  management dialog (create/duplicate/rename/delete/share/import).
- **Settings** — detected paths (Steam root, game directory, app data
  directory), launch preferences (silent Steam, pre-launch backup, tray
  icon), save backups (list/restore), a **Nexus Mods** section (API key,
  validate, get-key link, `nxm://` protocol toggle), the **Appearance**
  theme picker (six palettes, applied live), refresh the Thunderstore
  index, open logs/plugins/app-data folders.

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

## Parity round B: Nexus Mods, multiplayer safety, profile sharing, fun round

**Nexus Mods** (`Bifrost.Core/Services/NexusClient.cs`,
`WindowsCredentials.cs`, `NxmProtocolRegistrar.cs`,
`Models/NxmLink.cs`, `SingleInstance.cs`): stores the user's Nexus API key
via the Windows Credential Manager (`advapi32.dll` `CredWrite`/`CredRead`/
`CredDelete`, guarded by `OperatingSystem.IsWindows()`; falls back to a
dev-only plaintext file under app-data on non-Windows so `--check` can
exercise the logic here). Self-registers `nxm://` at startup
(`HKCU\Software\Classes\nxm`, Settings toggle, default on). Since a
Windows protocol launch always spawns a brand-new process, a second
launch detects the already-running instance (a named mutex) and forwards
its `nxm://` argument over a named pipe rather than opening a confusing
second window. `ModManager.InstallFromNexusAsync` downloads the resolved
CDN link and feeds it through the same install pipeline a dropped `.zip`
uses, recording `source: "nexus"` + the mod/file ids so
`UpdatesAvailableAsync` can check back with Nexus's own API later.

**Multiplayer safety** (`ModClassifier.cs`, `ServerJoinPlanner.cs`,
`ServerJoinViewModel`/`ServerJoinWindow`): classifies every installed mod
(curated table → Thunderstore category → keyword heuristic → Unknown)
into client-only / adds-items / world-altering / server-synced / unknown,
surfaced as a colored badge on Installed rows. The guided "Join a
Server…" window (Home tab) walks through picking a target profile,
reviewing the computed plan (with per-mod overrides — items mods default
to staying enabled with a warning, world-altering/unknown mods default to
disabled), and applying it: a pre-server safety backup first, then the
profile is marked a "guest" profile and reconciled against the real
install. Never disables anything until that final confirmed step.

**Profile sharing** (`ProfileShare.cs`, `ProfilesWindow`'s
Copy/Export/Import buttons, `ImportProfileViewModel`/`ImportProfileWindow`):
the exact same native JSON shape as the macOS app (`{"bifrost":1,"name":...,
"mods":[...]}`, base64 for a share code or pretty-printed as a
`.bifrostprofile` file) — cross-platform by design, so a code from either
platform imports on the other. Also interops with r2modman/Thunderstore
Mod Manager's own profile-code service
(`thunderstore.io/api/experimental/legacyprofile/`): exports a zipped
`export.r2x` YAML (hand-rolled minimal reader/writer, `System.IO.Compression`
in-memory rather than shelling out), uploads it, and returns a bare-UUID
code; importing auto-detects a pasted code's format (UUID vs. Bifrost's
base64) to pick the right importer. Every import previews exactly what
will install / is already present / can't be resolved (and why) before
anything touches disk.

**Fun round** (`Flavor.cs`, `RunestoneTips.cs`, `SagaStats.cs`,
`SurpriseMe.cs`, `WindowsAccessibility.cs`): 25 launch quips shown
alongside the real status line during a launch; 25 runestone
tips/lore lines rotating on Home; a Saga stats card built from Steam's
`localconfig.vdf` (playtime — same nested-VDF-path walk as the macOS
app, via a new `VdfParser.FindNestedValue`), the Valheim save directory
(worlds/characters), installed-mod classification counts, and backup
totals; a Surprise Me dice button in Browse; and a subtle celebration
pulse when a modded launch's BepInEx log confirms plugins loaded. Both
animated bits (the dice bounce and the celebration) check Windows'
reduced-motion setting (`SPI_GETCLIENTAREAANIMATION` via a small
`user32.dll` P/Invoke) and simply don't play if it's off, mirroring the
macOS app's own `accessibilityDisplayShouldReduceMotion` guards.

## What's ported from the macOS reference implementation

Ported 1:1 (same algorithms, Windows-appropriate I/O):
`ModManager` (resolve/install/uninstall/enable-disable/update, r2modman
payload-mapping heuristics, dependency resolution, Nexus install/update),
`ProfileStore` (apply/reconcile/sync/migration/guest profiles),
`ThunderstoreClient` (index fetch with `If-Modified-Since` conditional
revalidation), `Diagnostics` (BepInEx log classification),
`ThemePalette`/`ThemeStore` (see above), `NexusClient`, `ModClassifier`,
`ServerJoinPlanner`, `ProfileShare`, `Flavor`, `RunestoneTips`,
`SagaStats`, `SurpriseMe`.

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
Steam launch-options editing happens on Windows at all (`VdfParser` here
is read-only, extended in round B with a nested-block walker for Saga
stats' playtime lookup). The BepInEx config editor (arbitrary `.cfg` key
editing) is fully wired into the Windows UI — each Installed row with an
associated config gets a "Config" button opening an editor window, and
"Configs…" opens a full list.

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
compatibility (see above — skips on Windows), the config editor
(parser/writer round-trip, keyed apply, README fetch — real-file sections
skip on Windows), install-from-file, save backups, game-update detection,
Update All, index auto-refresh staleness, Launcher/silent-Steam planning,
the app settings store — and, added in parity round B: `nxm://` link
parsing, the Nexus credential store round trip (real Credential Manager
on Windows, dev fallback here), `nxm://` registry protocol registration
(**SKIPPED** on macOS — Windows-only), single-instance mutex + named-pipe
forwarding (runs for real here too — both are cross-platform .NET APIs),
the mod classifier (curated/category/heuristic fixtures, plus an
informational listing against this machine's real manifest.json), the
guided Join-a-Server planner (grouping/override/pre-server-backup/apply),
profile sharing (native round trip, `.bifrostprofile` file round trip,
version-mismatch rejection, and a **live** r2modman round trip against
the real Thunderstore endpoint), Saga stats fixtures, Flavor/Runestone
data-integrity checks, and the Surprise Me eligibility filter.

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
5. **(Parity round B, Windows-only paths)** Click a real "Mod Manager
   Download" link on a Nexus Mods page with Bifrost already running, and
   again with it closed, confirming both the registry association
   (`HKCU\Software\Classes\nxm`) and the single-instance forward actually
   work end to end on real Windows — the mutex+named-pipe mechanism
   itself is verified on macOS in `--check`, but the *registry*
   registration (`NxmProtocolRegistrar`) only SKIPs there and has never
   run for real.
6. Confirm the Windows Credential Manager round trip for the Nexus API
   key (Settings → Nexus Mods) — `--check` only exercises the dev-only
   plaintext fallback on this Mac.
7. Confirm the reduced-motion check (`WindowsAccessibility.AnimationsEnabled`,
   backing the Surprise Me dice bounce and the post-launch celebration)
   actually reads Windows' "Animation effects" setting correctly.

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
