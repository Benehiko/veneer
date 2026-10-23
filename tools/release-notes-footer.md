
---

## Installing

Veneer runs on Linux, x86-64. Download
`veneer-@VERSION@-linux-x86_64.tar.gz`, `SHA256SUMS` and
`SHA256SUMS.sigstore.json` into one directory, verify them
([below](#verifying-this-download)), then:

```sh
tar -xzf veneer-@VERSION@-linux-x86_64.tar.gz
./veneer-@VERSION@-linux-x86_64/install.sh
~/.local/bin/veneer doctor
```

`install.sh` copies Veneer under `~/.local`, or under the directory you
pass it, and points the menu entry at that copy, so the menu starts Veneer
even when that `bin` is not on your desktop's `PATH`.

Veneer needs a Vulkan driver. The
[user guide](https://benehiko.github.io/veneer/using-veneer.html) covers the
rest.

`veneer-@VERSION@-symbols.tar.gz` holds the debug info stripped from the
binary. You need it only to read a crash's stack trace.

## Verifying this download

We sign every release. The signature covers `SHA256SUMS`, which pins each
archive by hash. Run these two steps, **in this order**.

**1. Check the signature over the checksums.** Install
[cosign](https://docs.sigstore.dev/cosign/system_config/installation/), then
run:

```sh
cosign verify-blob SHA256SUMS \
  --bundle SHA256SUMS.sigstore.json \
  --certificate-identity @COSIGN_IDENTITY@ \
  --certificate-oidc-issuer @COSIGN_ISSUER@
```

It must print `Verified OK`. Anything else means we did not sign
`SHA256SUMS`: stop, and run nothing from the download.

**2. Check your archive against the checksums.**

```sh
sha256sum --ignore-missing -c SHA256SUMS
```

Your archive must show `OK`. Step 2 means nothing without step 1: checksums
from the same page as the archive prove only that the two agree, not that
either came from us.
