<p align="center"><img src="Resources/Assets.xcassets/MemoryGuardIcon.appiconset/icon_128x128.png" width="72" height="72" alt="Memory Guard nebula shield"></p>

# Memory Guard

[简体中文](README.zh.md) · macOS 13+ · [MIT license](LICENSE)

Memory Guard watches the Mac apps you choose and can pause the process behind a memory spike. It started with long-running ChatGPT and Codex sessions. You can give the same protection to other Mac apps, each with its own thresholds.

## Product statement

A coding agent can keep working long after you switch windows. If one of its helpers starts consuming gigabytes of memory, your first clue may be a lagging cursor or a Mac that is already swapping heavily. By the time you open Activity Monitor, it can be hard to tell which process grew and which one was simply large to begin with.

Memory Guard follows the app and its verified bundled helpers over time. When their combined footprint crosses your limit and the samples confirm abnormal growth, it can pause the individual process responsible. That buys you time to act. Pausing stops further allocations by that process. Ending it releases the memory it already holds.

## How Codex protection works

The first launch automatically adds a recognized, signed Codex installation. The recommended thresholds scale with your Mac's physical memory. A 64 GiB Mac uses the following defaults.

| Trigger | Default action |
| --- | --- |
| The Codex group reaches 32 GiB and shows sustained abnormal growth | Pause the verified process driving the increase. |
| A paused process goes unhandled for two minutes | Force-end that process. |
| The group reaches 40 GiB with abnormal growth and a verified culprit | Force-end the culprit immediately. |

A large, stable process can stay above a threshold without triggering an intervention. Force-ending a process can lose its current task. You can change both limits in **Thresholds**, adjust timeout and emergency behavior in **Applications**, and enable resuming paused processes in **Settings**.

## Make it fit your Mac

- **Choose the apps.** Add an app to monitor it, receive alerts, or enable automatic protection for verified components. The guard checks the signing identity and process start time before sending a signal.
- **See what grew.** Overview shows the app's last five minutes of memory use alongside system memory, pressure and swap. Enable the optional menu bar item to see the system memory percentage at a glance.
- **Keep monitoring light.** Samples and pause records stay in memory. Ordinary monitoring writes no periodic sample files. The default sampling interval is two seconds and event history expires after three days.
- **Close the window and keep working.** The guard continues in the background. Choose **Quit Completely** in Settings or in the application menu to stop both background helpers. Login startup is opt-in.

## Build and run

Use a Mac with Xcode and the macOS SDK installed. The project uses Swift, AppKit and SwiftUI and has no external package dependencies.

```sh
git clone https://github.com/sd800/memory-guard.git
cd memory-guard
bash scripts/build.sh release
mkdir -p "$HOME/Applications"
ditto --norsrc --noextattr "build/Memory Guard.app" "$HOME/Applications/Memory Guard.app"
open "$HOME/Applications/Memory Guard.app"
```

This builds a locally signed app. For an existing installation, quit it completely before replacing the bundle. To run the detection and process-control tests, use `bash scripts/test.sh`.

[Build and installation](docs/BUILD.md) · [How detection works](docs/ARCHITECTURE.md) · [On-device measurements](docs/VALIDATION.md) · [Changelog](CHANGELOG.md)

## License

Copyright © 2026 Songming.org. Available under the [MIT License](LICENSE).
