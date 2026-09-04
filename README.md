# Bifrost

A Valheim mod launcher/manager for macOS (Apple Silicon). Bifrost makes
running a modded Valheim on Mac painless by handling the parts that are
normally fiddly to do by hand:

- **BepInEx setup** — installs and keeps the [BepInEx](https://github.com/BepInEx/BepInEx)
  mod loader pack (`denikson-BepInExPack_Valheim`) in sync with your
  Valheim install, without ever touching your installed plugins or config.
- **Rosetta launch** — routes the modded launch through `arch -x86_64` so
  BepInEx's Intel-only doorstop shim runs correctly under Rosetta 2, since
  most Valheim mods still target the x86_64 build.
- **Steam-integrated launch** — points Steam's launch options at a small
  wrapper script so a normal "Play" click in Steam transparently launches
  modded (or vanilla) Valheim, with no manual steps per session.
- **Thunderstore mod manager** — browse, install, update, enable/disable,
  and remove mods from the [Thunderstore](https://thunderstore.io) Valheim
  mod repository, with automatic dependency resolution.

## Requirements

- macOS 14+ on Apple Silicon
- Rosetta 2 installed (`softwareupdate --install-rosetta` if you haven't
  already)
- Valheim installed through Steam
- Swift 6 toolchain to build (Command Line Tools are enough — Xcode is
  **not** required)

This project is a plain Swift Package Manager executable; it does not use
an `.xcodeproj`, `xcodebuild`, or `xcodegen`.

## Building

Run in development (shows a window via `swift run`):

```sh
swift build
swift run
```

Build a distributable `.app` bundle, ad-hoc code-signed and with an app
icon:

```sh
./scripts/bundle.sh
```

This produces `build/Bifrost.app`, ready to run or drag into
`/Applications`.

Headless diagnostics (no window) — runs every service against real and
throwaway-temp state and prints PASS/FAIL for each:

```sh
swift run Bifrost --check
```

## First run: the setup wizard

The first time Bifrost launches and it isn't fully ready to play modded,
it opens a setup wizard automatically. You can also re-open it any time
from **Settings → Run Setup Wizard**. It walks through, in order:

1. **Locate Valheim** — found via Steam's own library bookkeeping (never
   a guessed path), so this only works once Valheim has been installed
   (and ideally launched once) through Steam.
2. **Install BepInEx** — downloads the current `BepInExPack_Valheim` from
   Thunderstore and installs it next to `valheim.app`, plus Bifrost's own
   launch wrapper script. Skipped automatically (shown with a checkmark)
   if BepInEx is already installed.
3. **Configure Steam** — splices a `LaunchOptions` entry for Valheim in
   your Steam profile's `localconfig.vdf` so it invokes Bifrost's wrapper.
   This step shows exactly what it's about to do (quit Steam, back up
   `localconfig.vdf`, write the new value, relaunch Steam) before you
   confirm, and is skipped automatically if it's already configured.
4. **Done** — a summary, and a reminder to use **Play Modded** on the
   Home tab.

Every step is safe to retry, and none of it touches your saves or world
data.

## How the modded launch actually works

Steam can't be told "launch this game modded, but that other game
vanilla" — its launch options are just a command Steam wraps around the
game's own launch command. Bifrost solves this with a small always-on
wrapper:

1. The setup wizard sets Valheim's Steam launch option to:
   `"<Bifrost support dir>/launch/run_modded.sh" %command%`
2. Every time you click **Play** in Steam (or Bifrost's own **Play
   Modded**/**Play Vanilla** buttons, which just open `steam://rungameid`),
   Steam runs that wrapper instead of the game directly.
3. The wrapper reads a one-line `mode` file next to itself (`modded` or
   `vanilla`) — this is what Bifrost's Play buttons update right before
   launching — and either `exec`s Valheim normally (vanilla) or `exec`s
   it via `arch -x86_64 start_game_bepinex.sh` (modded), which boots
   BepInEx's doorstop shim under Rosetta before the game itself starts.
4. Every invocation is logged to `wrapper.log` next to the wrapper, and
   BepInEx logs its own startup (including how many plugins loaded) to
   `BepInEx/LogOutput.log` inside the game folder — Bifrost watches that
   log right after a modded launch and reports what it saw on the Home
   tab.

Launching Valheim directly from Finder or `open -a Valheim` bypasses this
wrapper entirely and always launches vanilla — mods only load through
Steam's own launch path.

## Where things live

| What | Where |
|---|---|
| Valheim install | wherever Steam put it (found via Steam's library bookkeeping, shown in Settings) |
| BepInEx pack, plugins, config | inside the Valheim folder, under `BepInEx/` |
| Bifrost's own data (Thunderstore cache, install manifest) | `~/Library/Application Support/Bifrost/` |
| Launch wrapper + mode file + wrapper.log | `~/Library/Application Support/Bifrost/launch/` |
| BepInEx's own log | `<Valheim folder>/BepInEx/LogOutput.log` |
| Steam launch options | your Steam profile's `localconfig.vdf` (`~/Library/Application Support/Steam/userdata/<id>/config/`) |

Settings has "Reveal in Finder" buttons for all of these, plus shortcuts
to open both logs directly.

## Troubleshooting

**Mods didn't load.**
Check `BepInEx/LogOutput.log` in the Valheim folder (Settings → Open
BepInEx Log, or Home tab after a modded launch) — if it's missing
entirely, check `wrapper.log` (Settings → Open Wrapper Log) to see
whether the wrapper actually ran and in which mode. Common causes:
Rosetta 2 isn't installed, or Steam's launch options were reset (see
below).

**Steam's "Verify integrity of game files" undoes BepInEx.**
Steam's verification only checks files it knows about from the game's
own manifest, so files BepInEx added next to the game (like
`doorstop_libs/`, `start_game_bepinex.sh`) are usually left alone — but
verification *can* still reset Valheim's own files if any were patched,
and some Steam updates silently reset a game's launch options back to
empty. If a modded launch stops working after a Steam update or a
"verify" pass, re-run the setup wizard (Settings → Run Setup Wizard) —
its Configure Steam and Install BepInEx steps are both safe to re-run and
will show as already-done if nothing actually changed.

**Setup wizard says Valheim can't be found.**
Bifrost only trusts Steam's own library folder list and app manifest —
it never guesses well-known paths. Make sure Valheim is installed through
Steam (not a stray copy elsewhere) and has been launched at least once,
then retry the "Locate Valheim" step.

**A specific mod's config keeps getting reset.**
Bifrost never overwrites an existing file under `BepInEx/config` when
installing or updating a mod — if a config keeps reverting, check whether
you're reinstalling from Browse rather than using Installed's per-mod
"Update" (which preserves the same protection, but it's worth checking
the mod's `enabled` toggle state too).
