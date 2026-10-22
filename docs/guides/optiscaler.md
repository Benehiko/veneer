# OptiScaler with Veneer

Veneer layers OptiScaler over a game without changing the game's files. It
needs an OptiScaler release on disk, which you can provide in one of two
ways.

## Option 1: let Veneer download it

```sh
veneer optiscaler install          # the newest release Veneer knows
veneer optiscaler install v0.9.3   # a specific one
veneer optiscaler releases         # what Veneer knows, and what is installed
```

In the window, choose **OptiScaler** under Upscaling, then **Download
OptiScaler**.

Veneer downloads the release from OptiScaler's GitHub page, checks it
against the SHA-256 pinned in `data/optiscaler.tsv`, and unpacks it into
`~/.local/share/veneer/optiscaler/<tag>`. A download that does not match is
deleted.

OptiScaler ships as a `.7z` archive, and Veneer unpacks it with a tool
already on your system. It uses the first of these it finds on `PATH`:

1. `bsdtar` (from libarchive)
2. `7zz` (7-Zip)
3. `7z` (7-Zip or p7zip)

If none is installed, install one:

| System | Command |
| --- | --- |
| Arch, SteamOS | usually present already, as pacman needs libarchive; otherwise `sudo pacman -S libarchive` |
| Debian, Ubuntu | `sudo apt install libarchive-tools` |
| Fedora | `sudo dnf install bsdtar` |
| openSUSE | `sudo zypper install bsdtar` |
| NixOS | add `pkgs.libarchive` to `environment.systemPackages` |

Before unpacking, Veneer lists the archive and refuses any entry with an
absolute path or `..`. After unpacking, it refuses the release if it holds a
symlink.

## Option 2: extract it yourself

1. Download a release from
   <https://github.com/optiscaler/OptiScaler/releases>.
2. Extract it into any folder **outside** your games, for example
   `~/OptiScaler/0.9.4`. Do not run its `setup_linux.sh`; Veneer does that
   job.
3. Tell Veneer where it is:

   ```sh
   veneer optiscaler ~/OptiScaler/0.9.4
   ```

   or, in the window, **Choose OptiScaler folder…**.

The folder must contain `OptiScaler.dll`.

## Turning it on

```sh
veneer set "Hell is Us" upscaling=optiscaler
veneer run "Hell is Us"
```

At launch Veneer links the release beside the game's executable inside the
game's private overlay, with `OptiScaler.dll` named `dxgi.dll`, and sets
`WINEDLLOVERRIDES=dxgi=n,b`. This is what OptiScaler's own setup script
does, without the copying. For Unreal Engine games it uses
`<Project>/Binaries/Win64`, beside the `-Shipping.exe`. In the game, press
**Insert** to open OptiScaler's menu.

Each game gets its own copy of `OptiScaler.ini`, in
`~/.local/share/veneer/overlay/<game>/upper/`, so settings you change in one
game stay with that game.

Games with EasyAntiCheat or BattlEye are refused.
