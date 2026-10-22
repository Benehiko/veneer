# Veneer

A Linux-native game launcher. Veneer finds your Steam library and the games
you add yourself, and runs them through Proton, Wine or natively, with
gamescope and [OptiScaler](https://github.com/optiscaler/OptiScaler) one
click away. It never touches game files: everything it adds is layered over
the game at launch and gone when the game exits.

**Status: pre-alpha.** The library, launching, gamescope, compatibility
checks and the window are built; see [docs/plan.md](docs/plan.md#status)
for what has been verified on real games.

## Use

```sh
veneer                                   # the window
veneer list                              # every game found
veneer run "ELDEN RING" --dry-run        # print the launch; change nothing
veneer set sekiro display=gamescope upscaling=fsr scale=67
veneer optiscaler ~/Downloads/OptiScaler_0.x   # an extracted release
veneer set "Hell is Us" upscaling=optiscaler
veneer doctor                            # what this system supports
```

`veneer help` lists every command and setting.

## Why

Getting gamescope and OptiScaler right through Steam's launch options is
tedious. OptiScaler's usual install copies DLLs into the game directory,
where a game update or a file check can break it, and whether it works at
all depends on the kernel, Mesa and ROCm versions. Launchers that solve this
tend to bury the player in settings. Veneer detects what it can, warns about
what will not work, and keeps the window small.

## Develop

```sh
nix develop   # Zig 0.17, make, git
make hooks    # once per clone: zig fmt check and tests before each commit
make build    # zig-out/bin/veneer
make test     # unit tests
make run      # build and run
make install  # veneer and its desktop entry under ~/.local (PREFIX=...)
```

## Docs

- [docs/plan.md](docs/plan.md): goals, design decisions and milestones
- [docs/architecture.md](docs/architecture.md): layout, hooks and the GUI stack
- [AGENTS.md](AGENTS.md): rules for contributors, human or agent
