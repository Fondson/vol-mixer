<img src="https://raw.githubusercontent.com/Fondson/vol-mixer/main/App/AppIcon.png" height="128" alt="Volume Mixer icon" align="left" />

<h3>Volume Mixer</h3>

Vibecoded Windows-style per-app volume control for macOS — a native SwiftUI mixer in the menu bar.

<br clear="all" />
<br clear="all" />

Built on **Core Audio Process Taps** (requires macOS 14.2+, Apple Silicon). No kernel extension, no virtual audio driver, no external dependencies.

<img width="552" height="187" alt="Volume Mixer screenshot" src="https://github.com/user-attachments/assets/128d5cbb-5fe5-4c55-8071-5d668f51eefb" />

## Install & Update

One-liner — downloads the latest prebuilt `.app`, installs to `/Applications`, launches it. No Xcode toolchain required:

```sh
curl -fsSL https://raw.githubusercontent.com/Fondson/vol-mixer/main/scripts/install.sh | bash
```

> Don't trust it? Don't run it. Every release is provenance-attested — [verify the download](SECURITY.md#verifying-a-download) before installing.

## Build from source

Requires the Swift toolchain (Xcode command line tools).

```sh
./scripts/build.sh
open "Volume Mixer.app"
```

First build auto-provisions a persistent self-signed cert (`scripts/setup-signing.sh`) so the TCC Audio Capture grant survives rebuilds. On first launch, macOS prompts for Audio Capture as soon as you move a slider — grant it in *System Settings → Privacy & Security → Audio Capture*, then quit and relaunch.

## CLI

The same binary ships a CLI for scripting:

```sh
"/Applications/Volume Mixer.app/Contents/MacOS/vol-mixer" list
"/Applications/Volume Mixer.app/Contents/MacOS/vol-mixer" run 6307 0.3
```

- `list` prints every process Core Audio tracks.
- `run <pid> <gain>` runs a foreground mixer; type a new gain + Enter to adjust live, Ctrl-C to release.

Running the CLI directly from `./build/release/vol-mixer` won't pass TCC — always invoke the CLI through the bundled binary path above, which inherits the `.app`'s identity and permission grant.

## Known limitations

- Core Audio Process Taps are macOS 14.2+. Earlier versions need a different approach (kext / virtual driver / Background Music).

## Security

Volume Mixer runs entirely as your normal user account — no background service running as administrator, no privileged helper. See [SECURITY.md](SECURITY.md) for the trust model and how to verify a download.

## License

MIT — see [LICENSE](LICENSE).
