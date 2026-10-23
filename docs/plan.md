# Plan

## Goal

A fast, Linux-native launcher that runs Windows and Linux games with
gamescope and OptiScaler set up correctly, without the player editing
Steam launch options and without touching game files.

## Name

**Veneer**: a thin layer laid over a surface without changing what lies
beneath. Veneer layers runners, gamescope and upscalers over a game and
leaves the install as it found it.

## License

GPL-3.0-or-later ([LICENSE](../LICENSE)), the license family of OptiScaler,
Lutris and Heroic. Every dependency is compatible: dvui (MIT), SDL3 (zlib),
FreeType, stb, and Inter (SIL Open Font License, shipped as
`share/licenses/veneer/Inter-OFL.txt`).

## Principles

The repository rules in [AGENTS.md](../AGENTS.md) enforce these.

1. **Game files are never written.** Hooks only: environment, injection,
   or an overlay visible to the game alone.
   ([architecture.md](architecture.md#hooks-without-touching-the-game))
2. **Few choices, good defaults.** Each game page shows Runner, Display
   and Upscaling. Everything else is detected or tucked into one collapsed
   advanced section.
3. **Warn before launch.** Known-bad combinations show a reason and a fix
   beside Play.
4. **Native and fast.** Zig 0.17, one binary, Wayland first with X11
   fallback, an idle window that uses no CPU.
5. **Nix for tooling, no containers.**

## Decisions

| Question | Decision |
| --- | --- |
| GUI toolkit | dvui on SDL3's GPU backend |
| Window font | Inter, embedded; pinned in `build.zig.zon` |
| OptiScaler's `.7z` | no 7z code in Veneer: use an extracted release, or unpack with the host's `bsdtar`, `7zz` or `7z` |
| Steam overlay outside Steam | load it, as Steam does: `gameoverlayrenderer.so` in `LD_PRELOAD`, `SteamOverlayGameId`, and Steam's Vulkan overlay layer |
| Third-party Protons | offer GE-Proton downloads, verified against GitHub's digest, into Steam's `compatibilitytools.d` |

## Status

| Milestone | Built | Verified |
| --- | --- | --- |
| M0 Scaffold | yes | yes |
| M1 Library | yes | yes, against a real Steam install |
| M2 Launch | yes | dry runs only |
| M3 gamescope | yes | dry runs only |
| M4 Window | yes | compiles; not yet opened on a desktop |
| M5 Compatibility checks | yes, with sourced Vulkan, Mesa, NVIDIA and OptiScaler rules | unit tests; no ROCm rule, for want of a source |
| M6 Hooks | yes | overlay blocked by the build sandbox; not yet run on a desktop |
| M7 OptiScaler | yes | download, verify, unpack and staging checked with v0.9.4; not yet in a game |
| M8 Runners | yes | GE-Proton download checked end to end; install progress, DXVK and VKD3D-Proton unit-tested only |
| M9 Release | `.desktop`, icon, `make install`, `make release`, Nix package, user guide | `nix build` succeeds; the Nix package's window and `make release` not yet run |

## Done

- **Library:** Steam roots (native and Flatpak) and libraries; binary
  `appinfo.vdf` for names, app types and launch entries; games added by hand;
  cover art; a cached scan.
- **Launching:** Proton discovery and Steam's tool mapping; the pure planner;
  Steam started for Steam games; native games through the scout runtime;
  logs per game; `--dry-run` that writes nothing.
- **gamescope:** Display and Upscaling to argv, capabilities from
  `gamescope --help`, output size from DRM.
- **Steam overlay:** the variables Steam sets, for Steam games, joined to
  any existing `LD_PRELOAD`.
- **Compatibility:** kernel, GPU, Vulkan driver, its Vulkan version and
  Mesa, ROCm, user namespaces, gamescope and display probes; sourced rules
  for Vulkan 1.3 (DXVK), Mesa 22.0 and NVIDIA 535 (VKD3D-Proton), and
  OptiScaler's FSR 4 on non-AMD GPUs; `veneer doctor`; launch refused on an
  error unless forced.
- **Hooks:** environment; the private overlay mount, with an error per
  refused step; `veneer-inject.exe`; anti-cheat refusal.
- **OptiScaler:** pinned releases with SHA-256; download, list-check,
  unpack with the host's tool, symlink check; staging as `dxgi.dll` with
  `dxgi=n,b`, beside the exe or the Unreal `-Shipping.exe`; per-game
  `OptiScaler.ini`; [guide](guides/optiscaler.md).
- **Runners:** Proton Experimental through `steam://install`, with its
  progress followed through Steam's app manifest; GE-Proton download, digest
  check, and native gzip, zstd and tar unpacking that refuses links leaving
  the build; a Wine binary per game with its own prefix, given pinned DXVK
  and VKD3D-Proton before its first launch.
- **Release:** `.desktop` entry and icon installed by `zig build`;
  `make release` with reproducible tarballs, `SHA256SUMS` and gpg
  signatures; a Nix package that fetches its Zig dependencies ahead of the
  build; a [user guide](guides/using-veneer.md).
- **Window:** dvui with Inter; library grid with cover art and search; game
  page with Runner, Display, Upscaling, render scale, HDR and Advanced;
  verdicts beside Play; Add game, Rescan, Download OptiScaler, Download
  GE-Proton; workers for scanning, launching and downloading.
- **Project:** GPL-3.0-or-later, Nix dev shell, git hooks, docs.

## To do

### Verify on a desktop

Each needs a display, a GPU, or mount rights the build sandbox lacks.

- [ ] The window opens in under 100 ms on a warm cache, idles at 0 % CPU,
      and runs natively on Wayland and on X11; Inter renders.
- [ ] `veneer doctor` lists the GPU and the Mesa or NVIDIA version.
- [ ] A Proton game and a native game start as they do from Steam; the Steam
      overlay opens with Shift+Tab.
- [ ] gamescope runs a game fullscreen at native resolution, with FSR.
- [ ] The overlay shows a test file only inside the game's namespace, and
      the install's checksum is unchanged afterwards. Proton's Steam Linux
      Runtime container sees the overlay.
- [ ] `--inject` loads a test DLL into a Proton game.
- [ ] OptiScaler's menu (Insert) appears in a DX12 game, and in an Unreal
      game such as Hell is Us.
- [ ] Install Proton Experimental from the window on a machine without
      Proton; run a game on a GE-Proton build Veneer downloaded; run a game
      on a custom Wine binary.

- [ ] Installing Proton Experimental from the window shows Steam's progress
      on the button and rescans when Steam finishes.
- [ ] A DirectX 11 and a DirectX 12 game run on a custom Wine binary through
      DXVK and VKD3D-Proton (`DXVK_HUD=1` shows), and the VKD3D-Proton
      `.tar.zst` unpacks.

### Build

- [ ] **Nix package (M9):** `nix build` succeeds; check the package
      opens the window on NixOS. On Arch it cannot: Nix's Vulkan loader
      finds no usable host driver.
- [ ] **First release (M9):** tag a version and run `make release` with the
      signing key.
- [ ] **ROCm rules (M5):** add one when a sourced ROCm requirement for
      games turns up; none was found.

## Open questions

| Question | Notes |
| --- | --- |
| Mount the overlay on every launch, or only when a hook needs it? | Today: only when needed. Always mounting keeps files the game writes beside its exe in one place; only-when-needed keeps plain launches identical to Steam's. Decide after the overlay runs on a desktop. |
| Systems that block unprivileged user namespaces: ship an AppArmor profile, or rely on injection? | Later. Ubuntu 24.04 and newer restrict them through AppArmor by default; Flatpak sandboxes forbid them. |
