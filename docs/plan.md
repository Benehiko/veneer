# Plan

## Goal

A fast, Linux-native launcher that runs Windows and Linux games with
gamescope and OptiScaler set up correctly, without the player editing
Steam launch options and without touching game files.

## Name

**Veneer**: a thin layer laid over a surface without changing what lies
beneath. Veneer layers runners, gamescope and upscalers over a game and
leaves the install as it found it. The word is short, easy to type in a
terminal, and does not collide with a known Linux gaming tool.

Also considered: *Overlay* (taken by every game overlay), *Shim* (too
technical), *Lens* (says upscaling but not launching). The name is settled.

## License

GPL-3.0-or-later ([LICENSE](../LICENSE)), the license family of OptiScaler,
Lutris and Heroic. Forks that ship must stay open, and code can move between
Veneer and those projects. Every dependency (dvui MIT, SDL3 zlib, FreeType,
stb) is compatible.

## Principles

The repository rules in [AGENTS.md](../AGENTS.md) enforce these.

1. **Game files are never written.** Hooks only: environment, injection,
   or an overlay visible to the game alone.
   ([architecture.md](architecture.md#hooks-without-touching-the-game))
2. **Few choices, good defaults.** Each game page shows Runner, Display
   and Upscaling. Everything else is detected or tucked into one collapsed
   advanced section.
3. **Warn before launch.** Known-bad combinations of kernel, Mesa, ROCm,
   GPU, Proton and gamescope show a reason and a fix beside Play.
4. **Native and fast.** Zig 0.17, one binary, Wayland first with X11
   fallback, an idle window that uses no CPU.
5. **Nix for tooling, no containers.**

## What the player sees

```
Veneer                  [ search...          ]   [ Add game ] [ Rescan ]
-------------------------------------------------------------------------
[cover] [cover] [cover] [cover]  |  ELDEN RING
[cover] [cover] [cover] [cover]  |  [          Play          ]
[cover] [cover] [cover] [cover]  |
                                 |  Runner     [ Automatic     v ]
                                 |  Display    [ Gamescope     v ]
                                 |  Upscaling  [ OptiScaler    v ]
                                 |  [ Choose OptiScaler folder… ]
                                 |
                                 |  Warning: ...
                                 |
                                 |  > Advanced
```

## Status

| Milestone | State |
| --- | --- |
| M0 Scaffold | done |
| M1 Library | done; checked against a real Steam install |
| M2 Launch | done; checked with dry runs, not yet by playing |
| M3 gamescope | done; checked with dry runs |
| M4 Window | built; not yet opened on a desktop |
| M5 Compatibility checks | done; needs sourced OptiScaler, Mesa and ROCm rules |
| M6 Hooks | built; overlay and injection not yet run outside the build sandbox |
| M7 OptiScaler | done; download, verify and unpack checked with v0.9.4; not yet run in a game |
| M8 Runners | done; not yet run |
| M9 Release | `.desktop` file and `make install`; packaging open |

## Milestones

Each milestone ends with tests passing, docs updated, and a pull request.
Headless commands come before the window so each layer can be tested on
its own.

### M0: Scaffold (done)

Nix flake dev shell, `build.zig` with `test`, `run` and `fmt`, the CLI
skeleton, git hooks, AGENTS.md and these docs.

### M1: Library (done)

Text VDF and binary appinfo parsers; Steam roots (native and Flatpak),
libraries and manifests; tools and runtimes filtered by app type; games
added by hand; the cached scan. `veneer list`, `add`, `remove`, `show`.

### M2: Launch without hooks (done)

Proton discovery and Steam's mapping; the pure planner; spawn, log and
wait; starting Steam for Steam games; native launches through the scout
runtime. `veneer run`, `runners`, `set`.

**Still to verify:** a Proton game and a native game start from Veneer
with the same result as from Steam.

### M3: gamescope (done)

Display and Upscaling to argv; capabilities from `gamescope --help`; output
size from DRM.

**Still to verify:** a game runs fullscreen at native resolution.

### M4: The window (built)

dvui on SDL3's GPU backend; Wayland first; event-driven redraw; library
grid with cover art and search; the game page; choices saved as they
change; cached library; workers for scanning and launching.

**Done when** the window opens in under 100 ms on a warm cache, idles at
0 % CPU, and runs natively on Wayland and on X11.

### M5: Compatibility checks (done)

Probes for kernel, GPUs, Vulkan driver and Mesa version, ROCm, user
namespaces, gamescope and display; `data/compat.tsv` with a source on every
row; verdicts on the game page and in `veneer doctor`.

**Still to do:** OptiScaler, Mesa and ROCm requirements, each with a source.

### M6: Hooks (built)

Environment hooks; `veneer-inject.exe`; the overlay mount; anti-cheat
refusal.

**Done when** a test DLL loads into a Proton game through `--inject`, a test
file appears in the game directory only inside the overlay, and a checksum
of the install is unchanged after both.

### M7: OptiScaler (done)

A release is linked into the game's overlay beside the exe (or the Unreal
shipping exe) as `dxgi.dll`, with `WINEDLLOVERRIDES=dxgi=n,b`, and a
per-game copy of `OptiScaler.ini`. The player either points Veneer at an
extracted release or lets it download a pinned one, which Veneer unpacks
with the host's `bsdtar`, `7zz` or `7z`; Veneer carries no 7z code
([guide](guides/optiscaler.md)). Adding a release is one row in
`data/optiscaler.tsv`, with the SHA-256 GitHub publishes for the asset.

**Done when** OptiScaler's menu appears in a DX12 game with the install's
checksum unchanged.

### M8: Runners (done)

Install Proton Experimental through Steam; pick a Wine binary for a game,
which then gets its own prefix.

**Done when** a machine with no Proton gets one from the window without
leaving Veneer.

### M9: Release

- Done: `data/veneer.desktop`, `make install`.
- `make release`: signed tarballs and checksums, as in
  elden-ring-mods-engine.
- An icon.
- A Nix package output in the flake. Zig fetches dvui and SDL at build
  time, so the package must pre-fetch them (`zig build --fetch` into a
  fixed-output derivation).
- A user guide.

Flatpak is out of scope: its sandbox blocks launching host Proton and
gamescope and creating namespaces, which Veneer needs.

## Open questions

| Question | Decide by |
| --- | --- |
| Distributions that restrict unprivileged user namespaces (Ubuntu's AppArmor policy): ship a profile, or rely on injection only? | M6 |
| Launching outside the Steam UI loses the Steam overlay and may lose playtime tracking. Preload Steam's overlay library, or accept the loss? | M2 |
| Third-party Protons (GE-Proton, Proton-EM): offer downloads from GitHub, or only list what the player installed? | M8 |
| A font for the window: ship one (Inter, OFL) or use dvui's default? | M4 |
