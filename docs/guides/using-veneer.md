# Using Veneer

Veneer runs the games in your Steam library, and games you add yourself,
through Proton, Wine or natively. It never changes a game's files.

## Install

From a release tarball:

```sh
gpg --verify veneer-<version>-x86_64-linux.tar.gz.asc
sha256sum -c SHA256SUMS --ignore-missing
tar -xzf veneer-<version>-x86_64-linux.tar.gz
cp -r veneer-<version>-x86_64-linux/{bin,share} ~/.local/
```

With Nix on NixOS: run `nix run .` in a clone of the repository, or add
the flake's `packages.default` to your system. On other distributions,
use a release tarball or `make install` instead. A Nix-built program finds
GPU drivers only where NixOS puts them (`/run/opengl-driver`), so there the
window fails with "No supported SDL_GPU backend found".

From source: `make install` puts Veneer, its desktop entry and its icon
under `~/.local` (set `PREFIX` to change that).

Veneer needs a Vulkan driver. gamescope, Steam and a `bsdtar`, `7zz` or
`7z` (for OptiScaler) are optional; Veneer tells you when one is missing.

## First run

Open **Veneer** from your desktop's menu, or run `veneer`. The window lists
every installed Steam game. **Add game** adds an executable Steam does not
know.

Run `veneer doctor` once. It lists your kernel, GPU, Vulkan driver and
gamescope, and any known problem with them.

## Play a game

Pick a game. The page shows three choices:

| Choice | What it does |
| --- | --- |
| **Runner** | Proton for Windows games, native for Linux games. Pick another Proton, a Wine binary, or download GE-Proton. |
| **Display** | Normal, or gamescope fullscreen at your screen's resolution. |
| **Upscaling** | Off, FSR or NIS (through gamescope, at a render scale you pick), or OptiScaler. |

Press **Play**. If Veneer knows the game will fail with these choices, it
says why and how to fix it beside the button, and does not start the game.
While the game starts and runs, the button shows the step (Starting,
Waiting for Steam, Running), and the line below it the runner. When the
game ends, that line says whether it closed or failed, why, and where its
log is.

Choices save as you change them. Everything else sits under **Advanced**:
environment variables, game arguments and gamescope arguments.

## Proton

If no Proton is installed, the game page offers **Install Proton
Experimental**. Steam downloads it; the button shows its progress, and the
game page updates when Steam finishes. Keep Steam open meanwhile.

**Download GE-Proton** in the Runner menu fetches the latest GE-Proton,
checks it against GitHub's checksum, and installs it where Steam finds it
too. Restart Steam to see it there.

## Wine

Choose **Choose a Wine binary…** in the Runner menu and pick a `wine`
executable. The game gets a Wine prefix of its own. Before its first launch
Veneer downloads DXVK and VKD3D-Proton, checks them, and installs them into
that prefix, so DirectX games run through Vulkan. This takes a minute once.

## OptiScaler

Set **Upscaling** to OptiScaler, then press **Download OptiScaler**, or
choose a release you extracted yourself. Press Insert in the game to open
OptiScaler's menu. See the [OptiScaler guide](optiscaler.md).

Do not use OptiScaler in online games: anti-cheat may ban you. Veneer
refuses to layer files into games that ship EasyAntiCheat or BattlEye.

## Jobs

Downloads, unpacking, setup and running games show in the jobs panel.
Press **Jobs** in the header to slide it in from the right; the button
shows how many jobs are running. Each job shows its step and, when Veneer
knows the size, a progress bar. A failed job says why. **Clear finished**
empties the list, and **Logs** opens the folder of launch logs
(`$XDG_STATE_HOME/veneer/logs`) in your file manager. Once a game has
closed or failed, its page has an **Open log** button for that game's log.

## The command line

Every feature works without the window. `veneer help` lists them all.

```sh
veneer list
veneer run "ELDEN RING" --dry-run
veneer set sekiro display=gamescope upscaling=fsr scale=67
veneer install-proton
```

## When something goes wrong

Each launch writes a log to `~/.local/state/veneer/logs/<game>.log`; the
launch before it is in `<game>.log.prev`. The first lines show the exact
command Veneer ran.
