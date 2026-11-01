# <img src="web/assets/memory-guard-1024.png" width="128" align="right" alt=""> Memory Guard<br clear="right">

[Simplified Chinese](README.zh.md)

Memory Guard watches the Mac apps you choose and can pause or end the process behind runaway memory growth.

## Product statement

Memory Guard started with a Codex session whose memory use suddenly climbed into the tens of gigabytes and crashed the Mac. The aim was to catch that kind of spike while there was still enough memory to respond.

It follows Codex and its verified bundled helpers, measuring both their combined footprint and how quickly each process is growing. When the group crosses a threshold and growth is confirmed, Memory Guard can pause the process responsible. At the emergency threshold it can end that process to release its memory.

The same protection is available for other Mac apps you select. Recommended thresholds adapt to your Mac’s unified memory capacity, and you can set different limits for each app.

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

## Privacy

Memory Guard works entirely on your Mac, including when you’re offline. Memory sampling, growth detection and protection decisions all happen on device. The app requires no account and includes no usage analytics or tracking.

Memory Guard reads process identity and memory counters. Your conversations, source code and document contents stay outside its monitoring scope. Recent samples stay in RAM. If you export diagnostics, the app saves a local report to the location you choose. The app never uploads it.

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

[Website](https://memory-guard.songming.org/) · [Build and installation](docs/BUILD.md) · [How detection works](docs/ARCHITECTURE.md) · [On-device measurements](docs/VALIDATION.md) · [Changelog](CHANGELOG.md)

## License

Copyright © 2026 Songming.org. Available under the [MIT License](LICENSE).
