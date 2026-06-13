# Security Policy

## Supported versions

Only the latest release receives fixes. Get it from the
[releases page](https://github.com/Fondson/vol-mixer/releases/latest).

## How Volume Mixer runs

- It runs entirely as your normal user account. There is no background
  service running as administrator and no privileged helper tool — so there
  is no elevated process that another app could trick into doing something on
  your behalf.
- The only special permission it requests is **Audio Capture**, which macOS
  asks you to grant the first time you move a slider. That permission is what
  lets it read another app's audio so it can replay it at a different volume.
- The only network connections it makes are to GitHub, to check for and
  download updates (on launch and once a day). Turn this off with the menu's
  **Automatically Update** toggle. It sends no telemetry and collects no data.

## Verifying a download

Every release is built by GitHub Actions and carries a signed build record
([SLSA provenance](https://slsa.dev/spec/v1.0/provenance)) that ties the
download to the exact commit it was built from. Check it before installing:

```sh
gh attestation verify Volume.Mixer.app.zip --repo Fondson/vol-mixer
```

An exit code of `0` means the file was produced by this repository's release
workflow and was not tampered with.

## Reporting a vulnerability

Please report security issues privately rather than opening a public issue:
open a private report under the repository's **Security → Report a
vulnerability** tab ([new advisory](https://github.com/Fondson/vol-mixer/security/advisories/new)).

You'll get a reply within a few days with confirmation and a fix plan.
