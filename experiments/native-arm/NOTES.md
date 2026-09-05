# Native ARM64 BepInEx experiment — RESULT: FAILED (upstream doorstop bug, newer versions too)

Date: 2026-09-05
Machine: M4 Mac mini, CommandLineTools only (no Xcode), macOS 26.5.2

## Goal

Determine whether modded Valheim (BepInEx 5.4.2333 + doorstop) can run natively
as arm64 instead of via Rosetta, by building UnityDoorstop for arm64 and
replacing the Intel-only `doorstop_libs/libdoorstop_x64.dylib` with a universal
(x86_64+arm64) build.

## Round 1 (earlier session): v4.4.0 — SIGBUS crash

See git history of this file / `crash_release_build.ips` / `crash_debug_build.ips`
for the original write-up. Summary: doorstop's own `plthook_open_real`
(classic lazy-bind/indirect-symbol-table parser, written for x86_64) crashes
with SIGBUS trying to parse arm64 UnityPlayer.dylib's symbol tables. Root
cause turned out to be that pre-4.5.0 `plthook_osx.c` has **no concept of
Mach-O chained fixups at all** — modern arm64 Mach-O images (Xcode 15+ era)
use `LC_DYLD_CHAINED_FIXUPS` instead of the classic `LC_DYLD_INFO` lazy-bind
tables, and the old code's blind assumptions about table layout walk off into
unmapped memory on such images.

Valheim's own Unity version: confirmed via `Info.plist` /
`UnityPlayer.dylib` strings to be **Unity 6000.0.61f1** — already in the
Unity 6 line, built with a toolchain that emits chained fixups for its arm64
slice. `UnityPlayer.dylib` and the main `Valheim` executable are both
universal (x86_64+arm64) — Unity's own arm64 support is not the blocker,
doorstop's is.

## Round 2 (this session): newer UnityDoorstop versions

### Investigation

- Cloned https://github.com/NeighTools/UnityDoorstop fresh into
  `build/UnityDoorstop/` (kept — useful for a future retry).
- Tags newer than v4.4.0: `v4.4.1` (no plthook changes), **`v4.5.0`**
  (2025-09-08, PR #62 "Support platform macosx/arm64" — a from-scratch
  rewrite of `plthook_osx.c` adding `LC_DYLD_CHAINED_FIXUPS` parsing,
  `uleb128`/`sleb128` decoding, and `__DATA_CONST`/`__got` section lookup).
  This is exactly the fix class needed for the Round-1 crash.
- `master` has no additional plthook commits beyond v4.5.0 (`git log
  v4.5.0..master -- '*plthook*'` is empty) — v4.5.0 is current upstream
  state for macOS.
- **DOORSTOP_\* env vars are unchanged** between v4.4.0 and v4.5.0
  (`git diff v4.4.0 v4.5.0 -- src/nix/config.c` only adds debug `LOG()`
  calls, no new/renamed vars) — fully compatible with the installed
  BepInEx 5.4.2333 pack's `start_game_bepinex.sh`.
- Upstream GitHub issues confirm this is a **known, still-open problem**:
  **issue #108** ("macOS: Doorstop cannot hook Unity 6000.3 Mono games —
  chained-fixups header parses as all zeros") describes v4.5.0 successfully
  injecting and the game running fine, but `read_chained_fixups()` returning
  an all-zero `dyld_chained_fixups_header` for UnityPlayer.dylib
  (`imports_count 0`, verbose build reports `"unknown imports format 0"`),
  so the `dlsym` hook is never installed and BepInEx's Preloader never gets
  control — **no crash, just silent failure** (no `LogOutput.log`, no
  `config/`). Reported independently for 3 other titles (Ages of Conflict,
  Global Rescue, Hearthstone), all Unity 6000.3.x. A community member
  (GitHub user "Celtech") posted a working patch as a **raw file attachment**
  on the issue — not merged, not part of the reviewable repo history, so per
  this session's safety rules against building/executing code from
  unvetted/untrusted sources, it was **not downloaded or built**.
  - A proper, reviewable open PR referencing #108 does exist:
    **PR #110** ("Fix cross-platform injection and launcher compatibility",
    NeighTools/UnityDoorstop, branch `mohui666:fix/open-issues-compatibility`,
    base commit `c957772`, same as `master`/`v4.5.0`+1). Its macOS-relevant
    diff (`src/nix/entrypoint.c` +158/-, `src/nix/plthook/plthook_osx.c`
    net -373 lines) rewrites the hook mechanism to use **dyld interposition**
    for `dlsym`/`fopen`/etc. instead of parsing/patching the GOT via chained
    fixups directly, explicitly to route around the #108 parsing bug. PR
    body explicitly claims to fix #108 (open, unmerged, `mergeable: false`
    against current master — has conflicts, not not to do with our subset).

### Build attempt 1 — v4.5.0 (tagged release)

- `git checkout v4.5.0`, `xmake f -m release -y`, `xmake build doorstop_arm64`
  (v4.5.0's `xmake.lua` now has dedicated `doorstop_x86_64`/`doorstop_arm64`
  targets with an `after_build` lipo step — that step itself failed since we
  didn't build the x86_64 sibling target, but the arm64 `.dylib` compiled
  and linked fine; grabbed it directly from
  `build/macosx/arm64/release/libdoorstop_arm64.dylib`).
  - Output: `libdoorstop_arm64_v4.5.0_release.dylib` — confirmed arm64 via
    `file`.
- `lipo -create` with the pristine x86_64 backup → `libdoorstop_universal_v4.5.0.dylib`,
  installed to `doorstop_libs/libdoorstop_x64.dylib`, mode set to
  `modded-native` (wrapper's new native branch — see below), launched via
  `steam://rungameid/892970`.
- **Result: matches issue #108 exactly.**
  - `sample <pid> 1` → `Code Type: ARM64` (genuinely native, not translated).
  - No crash, no `.ips` report.
  - Waited 35s: **no `BepInEx/LogOutput.log` ever created**, `config/` and
    `plugins/` timestamps unchanged from the last Rosetta run — doorstop
    injected and the game ran fine, but Preloader never got control.
  - This is a **new, independent 4th data point** for issue #108 (Valheim,
    Unity 6000.0.61f1 — slightly older than the reported 6000.3.x titles,
    same failure) — the bug is not limited to Unity 6000.3+.

### Build attempt 2 — PR #110 (dyld-interposition rewrite)

- `git fetch origin pull/110/head:pr-110 && git checkout pr-110`,
  `xmake build doorstop_arm64` (same recipe) — compiled and linked cleanly.
  Output: `libdoorstop_arm64_pr110_release.dylib`.
- `lipo -create` with the pristine x86_64 backup → `libdoorstop_universal_pr110.dylib`,
  installed, `modded-native` mode, launched.
- **Result: same silent failure as attempt 1.**
  - `Code Type: ARM64` confirmed, no crash, process alive and using CPU
    normally (menu music, Steam/PlayFab login would presumably proceed).
  - Waited ~100s total (well beyond the ~5s BepInEx normally takes under
    Rosetta): **no `LogOutput.log`** ever appeared, no crash report.
  - PR #110's dyld-interposition approach did not fix injection for
    Valheim's specific binary layout either (or some other part of its
    fail-closed guarding declined to hook here — could not get stderr from
    a Steam-launched GUI process to confirm which path was hit; `log show
    --predicate 'process == "Valheim"'` showed no doorstop debug output,
    consistent with fprintf(stderr,...) simply going nowhere for a
    Steam-spawned GUI app rather than the code not running at all).

Two build attempts used (v4.5.0 tagged, PR #110) — per the bounded-retry
scope, stopping here rather than pursuing the untrusted community patch or
further speculative branches.

## Where this leaves native-arm support

Still **not achievable**, and now for a *different* reason than Round 1:
- v4.4.0 (and everything before v4.5.0): **crashes** — no chained-fixups
  support at all in `plthook_osx.c`.
- v4.5.0 and PR #110 (current upstream `master` state and the most advanced
  known in-flight fix): **injects and runs without crashing, but never
  actually hooks anything** — BepInEx's Preloader is never invoked. This is
  an actively-worked-on, still-open upstream bug (issue #108, PR #110) as of
  this session's date, not something we introduced — three other named
  titles hit an identical wall, and we've now added Valheim as a fourth.
- The only reported *working* fix (Celtech's patch on issue #108) exists
  only as an unreviewed raw file attachment from an untrusted third party,
  not a mergeable/reviewable commit — deliberately not built or run here.

Two possible next steps if this is revisited later:
1. **Wait for PR #110 (or a successor) to land upstream** and re-test once
   NeighTools reviews/merges a real fix for #108 — check
   `git log master -- '*plthook_osx.c'` for new commits past `ae0bb92`
   (this session's `pr-110` HEAD) or a new tag past v4.5.0.
2. If truly desperate, independently re-derive Celtech's fix idea (chained-
   fixups parsing + dyld interposition for `dlsym`) from scratch by reading
   Apple's own `dyld` chained-fixups format docs/headers, rather than
   building an unvetted third party's binary/source — but this is a
   significant reverse-engineering undertaking, not a quick retry.

No "Native mode" toggle should be surfaced in Bifrost until this is resolved
upstream — it would silently produce an **unmodded** game (no crash, no
error, just quietly no mods loaded), which is arguably worse UX than the
Round-1 crash since it's not obviously broken to the user.

## Artifacts in this directory

- `build/UnityDoorstop/` — kept clone, currently checked out at `pr-110`
  (fetch refs: tags up to v4.5.0, `pr-110` = PR #110 head `ae0bb92`).
- `libdoorstop_arm64_v4.4.0_{release,debug}.dylib`, `crash_*.ips` — Round 1
  artifacts (crashing build + crash reports).
- `libdoorstop_arm64_v4.5.0_release.dylib`, `libdoorstop_universal_v4.5.0.dylib`
  — Round 2 attempt 1 (silent-fail, no crash report to keep).
- `libdoorstop_arm64_pr110_release.dylib`, `libdoorstop_universal_pr110.dylib`
  — Round 2 attempt 2 (silent-fail, no crash report to keep).
- `libdoorstop_x64_live_before_v4.5.0.dylib` — extra safety snapshot taken
  before the first swap this session (byte-identical to the pristine
  `.x86-backup`, redundant but harmless).

## End state (restored, working)

- `doorstop_libs/libdoorstop_x64.dylib` restored to the original Intel-only
  binary — verified byte-identical (md5 `404c4c4ce6d96c86693386fc4473563e`)
  against `doorstop_libs/libdoorstop_x64.dylib.x86-backup`.
- `~/Library/Application Support/Bifrost/launch/run_modded.sh` restored to
  its pre-experiment content — verified byte-identical (`diff`) against
  `run_modded.sh.rosetta-backup`. (Mid-session it briefly had an added
  `modded-native` branch using `exec arch -arm64 /bin/sh
  "$GAME_DIR/start_game_bepinex.sh" "$@"` — confirmed this correctly
  produces a genuinely native `Code Type: ARM64` process, so *that* part of
  the Round-1 finding about Steam's inherited x86_64 spawn preference still
  holds and is ready to reuse once doorstop itself is fixed upstream. Not
  kept in the restored file per the failure end-state.)
- Mode file set back to `modded` (Rosetta).
- Verified with a fresh launch: `Code Type: X86-64 (translated)` (expected
  for Rosetta mode), `Message: BepInEx] Chainloader started`, 13 `Loading
  [...]` lines (matches expected plugin count), no new errors beyond one
  pre-existing, unrelated `DllNotFoundException: AppleCoreNativeMac` (looks
  like a missing native helper for some optional feature, not
  doorstop/architecture related — was not flagged in the Round-1 end-state
  check, worth a separate look if it bothers anyone, but out of scope here).
- Process pkill'd after verification. No Valheim process left running.
