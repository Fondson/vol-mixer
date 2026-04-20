# vol-mixer

Vibecoded  Windows-style per-app volume control for macOS with a native SwiftUI mixer window.

Built on **Core Audio Process Taps** (requires macOS 14.2+). No kernel extension, no virtual audio driver, no external dependencies.

<img width="552" height="187" alt="image" src="https://github.com/user-attachments/assets/128d5cbb-5fe5-4c55-8071-5d668f51eefb" />

## Install & Update

One-liner — downloads the latest prebuilt `.app`, installs to `/Applications`, launches it. No Xcode toolchain required:

```sh
curl -fsSL https://raw.githubusercontent.com/Fondson/vol-mixer/main/scripts/install.sh | bash
```

> Don't trust it? Don't run it.

## Build from source

Requires the Swift toolchain (Xcode command line tools).

```sh
./build.sh
open vol-mixer.app
```

On first use the app will prompt for the **Audio Capture** permission as soon as you move any slider. Grant it in *System Settings → Privacy & Security → Audio Capture*, then quit and relaunch.

> Ad-hoc signing is fine for local use. The TCC grant is tied to the specific binary hash, so rebuilding will trigger a fresh prompt. If you want persistent grants, sign with a real Developer ID certificate.

## CLI

The same binary ships a CLI for scripting:

```sh
vol-mixer.app/Contents/MacOS/vol-mixer list
vol-mixer.app/Contents/MacOS/vol-mixer run 6307 0.3
```

- `list` prints every process Core Audio tracks.
- `run <pid> <gain>` runs a foreground mixer; type a new gain + Enter to adjust live, Ctrl-C to release.

Running the CLI directly from `./build/release/vol-mixer` won't pass TCC — always invoke the CLI through the bundled binary path above, which inherits the `.app`'s identity and permission grant.

## Known limitations

- Core Audio Process Taps are macOS 14.2+. Earlier versions need a different approach (kext / virtual driver / Background Music).
