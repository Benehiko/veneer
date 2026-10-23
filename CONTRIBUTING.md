# Contributing to Veneer

Thank you for helping. Read [AGENTS.md](AGENTS.md) first: its rules bind
every contributor, human or agent.

## Set up

```sh
git clone git@github.com:Benehiko/veneer.git
cd veneer
nix develop   # Zig, make, pandoc and pagefind
make hooks    # zig fmt check and tests before each commit
```

## Make a change

1. Open or pick an issue, or describe the change in your pull request.
2. Branch from `main`. `main` is protected: no one pushes to it directly.
3. Keep each pull request to one feature or fix.
4. Run `make fmt` and `make test` before you push.
5. If you change `build.zig.zon`, update `depsHash` in `flake.nix` and check
   that `nix build` passes.
6. If the change makes a doc under `docs/` untrue, fix the doc in the same
   pull request.

## Commits

Write the subject in the imperative, under 72 characters: "Find Steam cover
art in hashed librarycache subfolders". Explain why in the body; the code
carries no comments to do it for you.

## Pull requests

- Keep the body to 100 words or fewer.
- Show the change with a table or a Mermaid diagram when you can.
- If you add a setting, say why Veneer could not detect the value instead.
- If you add a compatibility rule under `data/`, cite its source.

A pull request merges once its conversations are resolved.

## License

By contributing, you agree to license your work under the
[GPL-3.0-or-later](LICENSE).
