# LibertyNet Releases

Public download host for **LibertyNet node** binaries. Source code lives in the
private `LibertyNetHQ/LibertyNet-hq` repository; only built artifacts are published here.

## Download

Get the latest macOS installer from the [Releases page](../../releases/latest).

- **LibertyNet-Node-0.1.0.pkg** — universal macOS installer (Intel + Apple Silicon).
  No Rust, no compiler, no Terminal required.

### Install

1. Download the `.pkg` from Releases.
2. The build is not yet Apple-notarized, so macOS Gatekeeper blocks a plain double-click.
   Open it once with **right-click (or Control-click) → Open → Open**, then enter your
   password. Every later launch of the installed node is automatic.
3. The installer creates your DID (shows a 12-word recovery phrase **once** — write it
   down offline) and loads a background agent that registers your node to the LibertyNet
   registry and heartbeats on login.

Verify a download with `shasum -a 256 LibertyNet-Node-0.1.0.pkg` against the checksum in
the release notes.
