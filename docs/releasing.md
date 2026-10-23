# Making a release

One machine builds, signs and publishes a release. It needs no CI, only
`nix develop`, which provides Zig, `llvm-objcopy`, `cosign` and `gh`, and a
browser.

## Before you start

- **A clean tree, with the release committed on `main`.** Every step
  refuses a dirty tree.
- **`gh auth status` reports a login** that may create releases on
  `Benehiko/veneer`.
- **`CHANGELOG.md` describes this version**, under `## v0.1.0` or
  `## Unreleased`. `make publish` refuses empty notes.

## 1. Tag

```sh
make tag VERSION=v0.1.0
```

This writes an annotated tag locally and pushes nothing. It refuses if the
tag exists; to redo it, `git tag -d v0.1.0` and run it again.

## 2. Build and sign

```sh
make release VERSION=v0.1.0
```

This refuses unless `HEAD` carries the tag. It runs the tests under
`-Doptimize=safe`, then builds each of `RELEASE_HOSTS`. It publishes nothing.

**It opens a browser.** Signing is keyless: cosign proves who you are through
GitHub. When GitHub asks which email to release, **choose the
`…@users.noreply.github.com` address.** It goes into Sigstore's public,
permanent transparency log, and it must match `COSIGN_IDENTITY` in the
Makefile, or nobody can verify the download.

A host `cosign` wins. Without one, `make release` runs the cosign image in
the first of `nerdctl`, `podman` or `docker`; `COSIGN=<command>` overrides
both. Keep `--user 0:0`, `-it` and `--network host` if you change it: the
first lets a rootless runtime write the bundle as you, the others carry the
browser login.

`dist/` then holds:

```
veneer-v0.1.0-linux-x86_64.tar.gz   bin/, share/, README.md, CHANGELOG.md
veneer-v0.1.0-symbols.tar.gz        debug info, for reading a crash's stack trace
SHA256SUMS                          every archive, by hash
SHA256SUMS.sigstore.json            the signature over SHA256SUMS
```

## 3. Look at it

```sh
cat dist/SHA256SUMS
tar -tzf dist/veneer-v0.1.0-linux-x86_64.tar.gz
cosign verify-blob dist/SHA256SUMS \
  --bundle dist/SHA256SUMS.sigstore.json \
  --certificate-identity 18033717+Benehiko@users.noreply.github.com \
  --certificate-oidc-issuer https://github.com/login/oauth
```

`make release` already checked that the native build reports
`veneer v0.1.0` and nothing more. A `-N-g<hash>` or `-dirty` suffix means the
build did not come from the tag.

## 4. Publish

```sh
make publish VERSION=v0.1.0
```

This checks `SHA256SUMS` against the files, cuts the notes from
`CHANGELOG.md`, appends `tools/release-notes-footer.md`, pushes the tag and
creates the release on GitHub. **It cannot be undone quietly.** Every step
before it is local.

## What a release contains, and why

**`safe`, not `fast`.** A safety check turns a bug into a panic with a stack
trace instead of silent corruption.

**Reproducible archives.** Names are sorted, owners are 0, every mtime is the
last commit's time and gzip stores no timestamp, so the same tag gives the
same bytes.

**Split symbols.** `llvm-objcopy` moves the debug info out of `bin/veneer`
and links the binary to `veneer-<host>.debug` by name and CRC. The
injector's `.pdb` goes in the same archive. No player downloads symbols.

**One signature, over the manifest.** `SHA256SUMS` pins every archive, so
signing it vouches for each.

## Adding a host

Add it to `RELEASE_HOSTS` with a `ZIG_TARGET_<host>` for its triple, as
`linux-aarch64` already has, and list it in `tools/release-notes-footer.md`.
`make release` checks the version only of the host it runs on.
