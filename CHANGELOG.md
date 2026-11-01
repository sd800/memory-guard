# Changelog

Versions follow `YY.M.NUM`; build numbers are monotonically increasing integers.

## 26.11.1 (6) — 2026-11-01

- Quit Completely stops the interface and both background services for the current session. It is available in Settings and directly below Quit Interface in the application menu, without a shortcut. Outstanding pauses must be resolved first.
- New installations keep the menu bar item hidden and show the system memory percentage by default when it is enabled. Existing choices are preserved.
- Publish the source under MIT with English and Simplified Chinese guides.
- Provide an Apple Silicon release ZIP and SHA-256 checksums.
- Keep generated app bundles in `build/Products.noindex/` so build copies do not appear alongside the installed app in Spotlight.

## 26.11.1 (5) — 2026-11-01

- Show “Monitoring pressure signals” / “压力信号监测中” until macOS delivers its first memory pressure event.

## 26.11.1 (4) — 2026-11-01

- Render the in-app sidebar mark at its native 1× or 2× size to keep the nebula smooth on Retina and standard displays.

## 26.11.1 (3) — 2026-11-01

### Added

- Native macOS menu bar app with a minimal deep-purple interface, English and Simplified Chinese.
- System memory overview, five-minute application footprint history, bounded local event history and redacted diagnostic exports.
- Explicit application protection list with bundle and code-signature verification, including signed bundled Codex helpers.
- RAM-adaptive warning, high, critical and emergency thresholds; configurable per application.
- Growth detection, hysteresis, sampling-gap invalidation and intervention cooldowns.
- Codex defaults: automatic pause, force-end after two minutes without a handling action, and immediate emergency termination for verified abnormal growth.
- Independent recovery service, crash-resilient, memory-only freeze journal, process-start identity checks and recovery after agent failure.
- Authenticated local XPC, current-session launchd supervision and optional login startup through ServiceManagement.
- Independent menu bar visibility and memory-percentage options, both disabled by default; login startup also disabled by default.
- Standard macOS shortcuts and native menu-item symbols.
- Aligned settings switches, a compact retention picker, and a three-day default event retention period, with 5/7/30/90-day options.
- About panel copyright: © 2026 Songming.org.
- Live language selection (System, Simplified Chinese, English) and full-row sidebar navigation.
- Immediate optimistic switches with serialized background updates and stable settings layout.
- Configurable 1/2/5-second normal sampling, with one-second high-risk sampling.
- Clear-diagnostics action that preserves freeze leases and the independent intervention safety journal.
- Flattened rounded nebula shield artwork, shared by the app, Dock and About panel through a compiled icon asset catalog.
- Self-memory budgets with launchd restart and independent freeze recovery.
- Bounded process/signature caches, hourly event expiry and sleep-gap recovery that cancels stale termination deadlines.
- Swift package tests, bounded process fixtures, an Xcode project and local build scripts.

- Dedicated Thresholds tab, per-app pause and emergency values, RAM-based recommendations and reset.
- Default-off resuming: paused processes can only be ended unless the user enables resuming; stale notification actions are rejected by the agent.
- Shared-memory heartbeats and pause records; append-only diagnostic events, no periodic sample or countdown writes.

### Scope

- Local personal build; no telemetry, cloud dependency, privileged daemon or automatic elevation.
- Only selected applications and verified bundled components can be controlled. External shells, standalone CLIs and development tools are excluded.
- Pausing does not release existing memory. A forced exit may lose active work. Long-duration stability and older macOS versions require separate runtime validation.
