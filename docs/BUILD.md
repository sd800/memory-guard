# Build and installation

## Requirements

- macOS 13 or newer; Apple Silicon is the primary target.
- Xcode with the macOS SDK, or a matching Swift toolchain and SDK.
- No external package dependencies. A paid developer account is not required for this local build.

## Command line

```sh
bash scripts/test.sh
bash scripts/build.sh release
mkdir -p "$HOME/Applications"
ditto --norsrc --noextattr "build/Products.noindex/Memory Guard.app" "$HOME/Applications/Memory Guard.app"
open "$HOME/Applications/Memory Guard.app"
```

The build script uses Xcode from `/Applications/Xcode.app` by default. Override `DEVELOPER_DIR` if necessary. Builds use two workers to bound compiler resource consumption. The output is locally ad-hoc signed, with separately signed helper executables. Set `SIGN_IDENTITY` to a valid identity to use certificate signing instead. Notarization is outside this personal release.

The generated app stays in `build/Products.noindex/` to keep build copies out of Spotlight searches. Release ZIP archives remain in `build/`.

For a permanent installation, copy the finished bundle to `~/Applications/Memory Guard.app` **before launching it**. Keep it at that location while the guard is running. Current-session launchd jobs retain absolute helper paths. For an update or move, choose **Quit Completely** in Settings or the application menu, replace the bundle and reopen it. If Memory Guard owns a paused process, resolve it in Overview first. The two helper jobs stop together with the interface and are registered again the next time you open the app.

## Xcode

Open `MemoryGuard.xcodeproj`, select the shared `MemoryGuard` scheme and build/run. The project has native app, agent and recovery targets and a local `MemoryGuardKit` Swift package dependency. Run package tests with `scripts/test.sh`. `scripts/generate_project.py` regenerates the checked-in project deterministically.

## First launch

- An installed, correctly signed Codex is added automatically on first launch. Its default policy pauses confirmed abnormal growth, ends an unhandled paused process after 120 seconds and immediately ends a confirmed emergency culprit.
- Other applications are added explicitly. Unverified applications can only be monitored.
- macOS may ask for notification permission. Ordinary same-user process control does not ask for an administrator password; a rejected operation is reported without elevation.
- Closing the window or choosing **Quit Interface** leaves the two current-session launchd jobs running. They are not installed in `~/Library/LaunchAgents`.
- **Start at login** registers the main app with `SMAppService`; the app then bootstraps the two session jobs. It is off by default. macOS background/login approval may be required when enabling it.
- When resuming is off, **Pause protection** requires ending any paused processes first. Turning off login startup does not stop protection in the current session.

- **Thresholds** (⌘4) edits each app's automatic pause and emergency force-end values. The overview shows the RAM-based recommendations on first use; **Use recommended**, then **Save**, returns to adaptive values.
- **Settings** (⌘,) includes 1/2/5-second sampling, language, event retention, and independent menu-bar visibility/percentage controls. The menu item defaults off, and enabling it shows the percentage by default. Previously saved preferences are respected. **Allow resuming paused processes** also defaults off: a paused process can only be ended until this option is enabled.

## Storage and removal

User state is in `~/Library/Application Support/MemoryGuard/`. Settings and safety event history are durable. Ordinary events append to a bounded log (three days by default). Heartbeats, live samples and freeze records are in shared or process memory; steady monitoring does not write periodic files. Clear diagnostics removes human-readable events, retaining active pause state and cooldowns. No command lines, environment variables or document contents are collected.

To uninstall, disable login startup, resolve any paused processes, choose **Quit Completely** and remove the app. The application-support directory may then be removed if history and settings are no longer needed.

## Versioning

Update `Config/Info.plist`, `Config/Version.xcconfig`, `Sources/MemoryGuardKit/Models.swift`, and the generator's version settings together. `26.11.1` is the first November 2026 release. Increment the integer build number for each distributed build, including rebuilds with the same calendar version. Maintain the English changelog.
