# LibertyNet — Releases

Public distribution of the **LibertyNet node** binaries and installers.
**Source code stays private** in `LibertyNetHQ/LibertyNet-hq`; only build outputs are published here.

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

## Integrity

Each release lists the **source commit SHA** it was built from and the binary's
`sha256`. Verify the download's `shasum -a 256` matches before installing.
