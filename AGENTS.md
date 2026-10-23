# AGENTS.md

Rules for anyone, human or agent, who works on Veneer.

## 1. Never write to a game's install

Veneer does not create, change, rename or delete any file under a game's
install directory. It changes how a game runs only through the hooks
described in [docs/architecture.md](docs/architecture.md#hooks-without-touching-the-game):
environment, DLL injection, and an overlay mount that exists only inside the
game's own namespace. A feature that needs a file in the game directory uses
the overlay, or it does not ship.

## 2. Keep the window small

Every game shows a few choices, each with a working default. Before you add
a setting, try to detect the value instead. If you must add one, it goes in
the collapsed advanced section. Say in the pull request why detection could
not do it.

## 3. Warn before launch, not after a crash

If Veneer knows a combination will fail (kernel, Mesa, ROCm, GPU, Proton or
gamescope version), it says so on the game page before the player presses
Play, with the reason and the fix. The rules live as data in `data/`, each
with its source.

## 4. No Python

Write no Python and run no Python while developing Veneer. Use Zig, shell,
or the tools the build already provides.

## 5. No code comments

Do not write code comments. Explain a change in its commit message. Two
kinds may stay, and both should be rare:

- `// TODO: ` followed by the unfinished work, on one line.
- A fact the code cannot show and a reader cannot work out, such as why a
  Proton environment variable must be set in a certain order. If it fits in
  a doc under `docs/`, put it there instead.

## 6. Write plainly

Follow Strunk and White in all documentation. Be precise. Be brief. Omit
needless words.

## 7. Test algorithms, not constants

A test asserts that an algorithm does what it claims. Do not assert the
value of a constant, and do not add a function only so a test can reach
code. Prefer fast unit tests that need no Steam install, no GPU and no
display: feed parsers text fixtures and argv builders plain structs.

## 8. Use Nix

Provide development tooling through Nix (`nix develop`). Zig builds
everything else from source.

## 9. Every feature gets a pull request

Never commit to `main` directly. Work on a branch and open a pull request
whose body has at most 100 words. Show the change with a table or a Mermaid
diagram when you can; use GitHub's default theme.

## 10. Keep docs true

`docs/plan.md` holds the roadmap until the work moves into GitHub issues.
Every other page under `docs/` describes what the code does now. When code
changes a fact a doc states, change the doc in the same pull request.
