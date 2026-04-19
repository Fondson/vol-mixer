# vol-mixer

Per-app volume control for macOS with a native SwiftUI mixer window. Built on **Core Audio Process Taps** (requires macOS 14.2+). No kernel extension, no virtual audio driver, no external dependencies.

## Build & run

```sh
./build.sh
open vol-mixer.app
```

That's it. `build.sh`:

1. `swift build -c release`
2. Assembles `vol-mixer.app/Contents/{MacOS,Resources,Info.plist}`
3. Ad-hoc codesigns the bundle (`codesign -s -`)

On first use the app will prompt for the **Audio Capture** permission as soon as you move any slider. Grant it in *System Settings → Privacy & Security → Audio Capture*, then quit and relaunch.

> Ad-hoc signing is fine for local use. The TCC grant is tied to the specific binary hash, so rebuilding will trigger a fresh prompt. If you want persistent grants, sign with a real Developer ID certificate.

## The UI

![layout]

vol-mixer lives in the menu bar — no dock icon, no standalone window. Click the speaker icon to drop a popover; right-click for a small menu (Launch at Login, Quit). First launch auto-registers as a Login Item; toggle off from that menu if unwanted.

Inside the popover:

- Output device picker — switches the system default output. Any active mixers are torn down and rebuilt against the new device automatically (same behaviour if the default is changed externally from Sound settings).
- One row per process that's currently producing audio, plus any process with an active mixer (stays on screen even after it stops playing).
- Icon + localized app name, a percentage label, a mute button, and a per-row reset.
- Slider: 0 → 1.5 linear gain. Anything below 100% attenuates, above 100% boosts (hard-clips at full scale).
- Reset button: tears down the tap and returns the process to its native mixer.
- "Reset all" in the header: releases every tap at once.
- List auto-refreshes every 2 s.

When you move a slider or mute, vol-mixer lazily creates the tap for that PID — processes you never touch are never intercepted.

## CLI

The same binary ships a CLI for scripting:

```sh
vol-mixer.app/Contents/MacOS/vol-mixer list
vol-mixer.app/Contents/MacOS/vol-mixer run 6307 0.3
```

- `list` prints every process Core Audio tracks.
- `run <pid> <gain>` runs a foreground mixer; type a new gain + Enter to adjust live, Ctrl-C to release.

Running the CLI directly from `./build/release/vol-mixer` won't pass TCC — always invoke the CLI through the bundled binary path above, which inherits the `.app`'s identity and permission grant.

## How it works

1. Enumerate audio-producing processes via `kAudioHardwarePropertyProcessObjectList`.
2. Build a stereo-mixdown `CATapDescription` on the target process with `muteBehavior = .mutedWhenTapped` — the source is silenced at the system mixer only while our IOProc is actively reading, so `AudioDeviceStop` is enough to let the process resume hardware playback on its own.
3. Create a private aggregate device whose *input* is the tap and whose *output sub-device* is the current default output, with `kAudioAggregateDeviceTapAutoStartKey = true`.
4. Install an IOProc on the aggregate that reads the tapped float32 samples, multiplies by the current gain (held behind an `OSAllocatedUnfairLock`), and writes the result into the output buffer. One `memcpy` on the unity-gain fast path.
5. Tear-down on reset / quit: `AudioDeviceStop` + `AudioDeviceDestroyIOProcID` + `AudioHardwareDestroyAggregateDevice` + `AudioHardwareDestroyProcessTap`.
6. Watch `kAudioHardwarePropertyDefaultOutputDevice` — if the default output changes (via our picker or externally), stop every active mixer and re-create it against the new device so audio keeps flowing.

## File layout

```
Package.swift
App/Info.plist                 NSAudioCaptureUsageDescription + bundle metadata
build.sh                       swift build → .app → ad-hoc codesign
Sources/vol-mixer/
  main.swift                   top-level entry: dispatches CLI vs GUI
  CLI.swift                    list / run subcommands with stdin gain control
  AppDelegate.swift            NSStatusItem + NSPopover host, launch-at-login
  ContentView.swift            SwiftUI popover (output picker + process rows)
  MixerStore.swift             @Observable store, process list, mixer registry, default-output watcher
  AudioProcessList.swift       Core Audio process enumeration
  OutputDeviceList.swift       Output-device enumeration + default-device get/set
  CoreAudioHelpers.swift       Typed wrappers around AudioObjectGetPropertyData
  VolumeMixer.swift            Tap + aggregate + IOProc render loop
```

## Known limitations

- Core Audio Process Taps are macOS 14.2+. Earlier versions need a different approach (kext / virtual driver / Background Music).
- No limiter. Gain > 1.0 hard-clips on the way to the output buffer.
- `muteBehavior = .mutedWhenTapped` silences the process only while the IOProc is running, so every teardown path (`Reset`, `Reset all`, quit, `applicationWillTerminate`, `deinit`, SIGINT, SIGTERM) immediately restores native playback. If the app is SIGKILLed mid-flight, Core Audio recovers the orphaned aggregate on the next coreaudiod restart.
