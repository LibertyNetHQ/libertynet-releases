# LibertyNet — Releases

Public distribution of the **LibertyNet node** binaries and installers.
**Source code stays private** in `LibertyNetHQ/LibertyNet-hq`; only build outputs are published here.

## ✅ Verify before you install

Every release artifact here is signed with **cosign keyless (Sigstore + GitHub OIDC)** —
no long-lived private key, no public key to distribute. The trust root is the
**public Sigstore transparency log**.

```bash
cosign verify-blob \
  --bundle "<artifact>.sigstore.json" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  --certificate-identity-regexp '^https://github\.com/LibertyNetHQ/libertynet-releases/\.github/workflows/sign-release\.yml@refs/' \
  "<artifact>"
```

`Verified OK` means the file was **signed by this repo's `sign-release.yml` workflow and
has not been altered since**. The two `--certificate-*` flags are the whole point — do not
drop them; without them a valid signature proves nothing about *who* signed.

**It does NOT prove the binary was built from any particular source commit.** Build
provenance (SLSA) is *planned*, not done — the commit SHA in the release notes is currently
unverifiable from the outside. It is also **not** Apple notarization.

👉 Full guide, honest scope, and the `ln-node` caveat: **[docs/VERIFYING.md](docs/VERIFYING.md)**

## macOS

The installer is a **universal** `.pkg` (Apple Silicon + Intel from one binary):
`libertynet-init` + `portal-daemon` → `/usr/local/bin`, creates your DID (shows the
12-word recovery phrase once), and starts the node as a per-user LaunchAgent.

### ⚠️ Opening an unsigned build (right-click → Open)

Releases here are **not yet Apple-signed/notarized**, so Gatekeeper will block a
double-click. To install:

1. Download the `.pkg`.
2. **Right-click** (or Control-click) the file → **Open** → confirm **Open** in the dialog.
   (Do this instead of double-clicking; it tells Gatekeeper you trust this build.)
3. Follow the installer. Write down your 12-word recovery phrase when shown.

Apple signing + notarization is planned; until then the right-click-Open step is required.

> Cosign verification (above) is the stronger check and works today — Gatekeeper's
> complaint is about an Apple certificate we don't have yet, not about integrity.

## Integrity

Each release lists the **source commit SHA** it was built from and the binary's
`sha256` (`SHA256SUMS-*.txt`). The checksum file is itself cosign-signed, so it is a real
trust anchor rather than a self-referential one: verify `SHA256SUMS-*.txt` with cosign
first, then `shasum -a 256 -c` against it.

## `install.sh`

[`install.sh`](install.sh) in this repo is the canonical source of the one-liner served at
`https://libertynet.ai/install.sh`. Its SHA256 check is **fail-closed**: a missing,
malformed, or mismatched checksum aborts the install with a non-zero exit — there is no
skip switch. Enforced by [`tests/test-install-sh.sh`](tests/test-install-sh.sh) and a daily
CI job that diffs the deployed copy against this one.

## CI

| Workflow | What it does |
|----------|--------------|
| [`sign-release.yml`](.github/workflows/sign-release.yml) | Signs every artifact on `release: published` (keyless), self-verifies, uploads `.sig` / `.pem` / `.sigstore.json` |
| [`verify-release.yml`](.github/workflows/verify-release.yml) | Daily: a clean runner verifies the latest release **as an outsider** — anonymous download, no repo secrets, plus a tamper-must-fail negative case |
| [`ci.yml`](.github/workflows/ci.yml) | shellcheck + `install.sh` fail-closed tests + drift check against the deployed `libertynet.ai/install.sh` |
