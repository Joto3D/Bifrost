# Bifrost

A Valheim mod launcher/manager for macOS. Bifrost aims to make running a
modded Valheim on Mac painless by handling:

- **BepInEx setup** — installing and keeping the BepInEx mod loader in sync
  with your Valheim install.
- **Rosetta forcing** — ensuring Valheim (and BepInEx) launch under Rosetta
  2 where needed, since many mods target the x86_64 build.
- **Steam-integrated launch** — launching Valheim through Steam with the
  right launch options so mods actually load.
- **Thunderstore mod manager** — browsing, installing, updating, and
  removing mods from the [Thunderstore](https://thunderstore.io) Valheim
  mod repository.

This is an early scaffold — the app currently just shows a placeholder
window with Home, Browse, Installed, and Settings tabs.

## Requirements

- macOS 14+
- Swift 6 toolchain (Command Line Tools are enough — Xcode is **not**
  required)

This project is a plain Swift Package Manager executable; it does not use
an `.xcodeproj`, `xcodebuild`, or `xcodegen`.

## Building

Run in development (shows a window via `swift run`):

```sh
swift build
swift run
```

Build a distributable `.app` bundle:

```sh
./scripts/bundle.sh
```

This produces `build/Bifrost.app`, ad-hoc code-signed and ready to run.
