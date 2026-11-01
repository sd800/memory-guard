# Release validation — 26.11.1

Test host: Apple Silicon, 64 GiB physical memory, macOS 26.7.2. The release is locally signed for this personal installation.

## Protection

The 29 Swift package tests passed with zero failures and no skipped process fixtures. They cover adaptive thresholds, stable large processes, growth windows, critical pause, immediate emergency termination, cold starts, membership/sampling gaps, PID reuse and signing boundaries, cooldowns, journal migration, corruption, partial event records, and bounded memory history.

Integration tests used a disposable helper, not a production Codex session. They sent real STOP/CONT/KILL signals, exercised recovery with a dead owner and expired lease, and advanced the guard's clock to test the configured timeout. With resuming disabled, the fixture remained stopped after a simulated owner loss, survived attempted stale resume/hold/normal-exit commands, and was ended through the manual termination action. The pause journal used no regular file. Full-quit tests checked the outstanding-pause interlock and removal of both session jobs in order. Migration tests checked the enabled percentage default and preservation of a saved opt-out. Tests did not intentionally exhaust the machine's RAM.

## On-device inspection

- The release script signs both helpers and the app, strictly verifies the staged app, and extracts and strictly verifies the release ZIP. The installed copy was also strictly verified. The native Xcode Release scheme builds with the compiled asset catalog.
- The installed UI showed an active guard and the bundled Codex app (verified bundle ID and team). The dedicated Thresholds tab displayed 32 GiB pause and 40 GiB emergency for this Mac, as did Overview.
- Settings displayed the default-off resume option, optional login and menu item, two-second sampling and three-day retention. The language override and Command-comma navigation were exercised on device. Current user preferences are preserved on updates.
- The high-resolution source rendered with noisy edges when reduced at runtime. Build 4's actual Retina sidebar showed a smooth shield and a coherent nebula using the native 64-pixel representation. Build 5's installed Overview displayed “Monitoring pressure signals”; its Simplified Chinese string is “压力信号监测中”.

- On build 6 the native app menu placed Quit Completely directly below Quit Interface. Activating it removed both launchd jobs and exited all three processes. Reopening the installed app registered both services and displayed active Codex monitoring again.

## Disk and memory measurement

The installed guard watched the actual signed Codex app at the default two-second interval with no incident. Seven samples over 60 seconds used libproc's physical-footprint and disk-write counters, cumulative process CPU time, and before/after metadata for every file in MemoryGuard's support directory. Both PIDs remained stable. This measurement was on build 3; builds 4 and 5 changed presentation and version metadata only.

| Helper | Mean CPU, % of one core | Physical footprint, first → last (peak) | Additional disk bytes written |
| --- | ---: | ---: | ---: |
| GuardAgent | 0.38% | 19.02 → 16.55 MiB (19.06) | 0 |
| GuardRecovery | 0.03% | 2.98 → 3.03 MiB (3.03) | 0 |

No support file was added, replaced, resized, or modified in that interval. These are process-attributed counters, not whole-device NAND writes. Events, settings, user exports and the operating system can still write to disk. Freezing stops execution but does not return the target's allocated memory or turn off system swap.

Reproduce without persistent measurement output: run `python3 scripts/measure_runtime.py` in a terminal while the app's jobs are running. The measurement script is not shipped or scheduled with the app.

The history test simulates 72 hours of samples; a multi-day real-time soak, sleep/logout/login cycle on every supported macOS release, and runtime validation on macOS 13 remain unverified.
