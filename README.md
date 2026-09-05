# Bifrost (Windows)

A Windows port of [Bifrost](https://github.com/), the Valheim mod
launcher/manager. The reference implementation is a native macOS SwiftUI
app; this repo re-implements the same app shell and eventual feature set
(BepInEx setup, Steam-integrated modded/vanilla launch, Thunderstore mod
browsing/install) for Windows using [Avalonia UI](https://avaloniaui.net/)
on .NET, with an MVVM architecture via
[CommunityToolkit.Mvvm](https://learn.microsoft.com/dotnet/communitytoolkit/mvvm/).

**Status: scaffold.** The app shell, navigation, and publish pipeline are
in place; the actual mod-management logic (game locator, BepInEx
installer, Steam launch-options config, Thunderstore client) has not been
ported yet — those land in `src/Bifrost.Core`.

## Layout

```
bifrost-windows.sln
src/
  Bifrost/         # Avalonia app: views, view models, app shell
  Bifrost.Core/    # platform-neutral class library: Thunderstore client,
                   # install manifest, profiles, config parsing (stubs for now)
scripts/
  publish-win.sh   # builds a self-contained win-x64 single-file Bifrost.exe
```

The four tabs (Home / Browse / Installed / Settings) mirror the macOS
app's tab layout; each is currently a placeholder view.

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

Mirrors the macOS app's `Bifrost --check` mode: runs a stub self-test and
exits before any UI initializes.

```sh
dotnet run --project src/Bifrost -- --check
```

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

- Targets `net10.0`. The Avalonia MVVM template defaults to `net8.0`; it
  was retargeted after confirming a clean `dotnet restore`/`build` on
  `net10.0`.
- `Bifrost.Core` holds placeholder types (`ThunderstorePackage`,
  `Profile`, `InstalledManifest`, `ThunderstoreClient`, `ProfileStore`,
  `ConfigParser`, `SelfTest`) shaped after the macOS app's `Models/` and
  `Services/` folders, ready to be filled in with real logic (HTTP calls,
  file I/O, Windows-specific paths) as each service is ported.
