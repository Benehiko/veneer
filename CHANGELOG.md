# Changelog

What Veneer does, in the words of someone using it. Each release is on the
[Releases page](https://github.com/Benehiko/veneer/releases); `make publish`
takes its notes from the section that names the version, or from
`## Unreleased`.

## v0.1.0

The first release. Veneer is pre-alpha: it finds and plans launches
reliably, but most of what it does in a running game has not yet been
checked on a real desktop. Report what breaks.

- **Library.** Lists every installed Steam game, native or Flatpak, with
  cover art. **Add game** adds any other executable.
- **Three choices per game.** Runner, Display and Upscaling, each with a
  working default. Everything else sits under **Advanced**.
- **Runners.** Proton, Proton Experimental installed through Steam,
  GE-Proton downloaded and checked, or a Wine binary of your own with DXVK
  and VKD3D-Proton set up for you.
- **gamescope.** Fullscreen at your screen's resolution, with FSR or NIS
  at a render scale you pick.
- **OptiScaler.** Downloaded, checked and layered over the game at launch,
  never copied into it. Games with EasyAntiCheat or BattlEye are refused.
- **Warnings before Play.** Veneer checks your kernel, GPU, Vulkan driver
  and gamescope, and says why a launch would fail and how to fix it.
  `veneer doctor` shows the same checks.
- **Jobs and logs.** Downloads and launches show their progress in the
  jobs panel. Each launch keeps a log, one click away.
- **Command line.** Every feature works without the window; `veneer help`
  lists them.
- **Desktop.** A menu entry and icon, and the window groups under them in
  the dock.
- **Signed releases.** Each download is pinned in `SHA256SUMS`, signed
  with cosign.
