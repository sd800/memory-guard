# Architecture and intervention contract

## Components

- **MemoryGuard**: AppKit lifecycle and native menus, SwiftUI views, bilingual copy, notifications, policy editing and diagnostics.
- **GuardAgent**: serial monitoring and command queue, process discovery, footprint sampling, growth detector and authorized signals.
- **GuardRecovery**: separate process, two-second checks of paused processes. With resuming enabled, it releases an expired or orphaned pause after identity validation. With resuming off (default), it preserves the pause for manual termination and cancels stale deadlines. It never executes timeout kills.
- **MemoryGuardKit / CGuard**: models, bounded histories, storage, Security framework verification, XPC and a small public libproc/Mach VM bridge.

Both helpers run as the signed-in user. launchd supervises them independently. At normal startup, the UI submits session-specific jobs using `launchctl bootstrap gui/<uid>`; the property lists live in application support, not a login-scanned directory. This makes **login startup genuinely optional** while allowing the interface to exit. `SMAppService.mainApp` implements opt-in login startup. Packaged agent property lists document the equivalent bundled service structure; they are not separately registered on normal startup.

The agent publishes a named Mach service. Every XPC connection enforces the peer's designated code-signing requirement, using `NSXPCConnection.setCodeSigningRequirement`; same-user access is also checked. Ad-hoc builds are pinned to the installed binaries' designated requirements. Replacing binaries requires restarting their jobs.

## Identity and scope

Selection stores bundle ID, designated requirement, Team ID and a path hint. Running roots must match that identity. Helpers must be inside a verified bundle, have the same signing team and belong to the verified root's parent chain (or be an already-known surviving member). A separately launched packaged CLI is not adopted. External shells, Node, Python, compilers and unrelated apps are excluded even if descendants.

The same PID, UID, executable path, start seconds/microseconds and live code hash are rechecked immediately before every signal. No process-group or recursive tree signals are used. An identity check and POSIX `kill` are separate kernel calls: the implementation minimizes but cannot mathematically eliminate their final time-of-check/time-of-use race on every supported macOS version. It does not use private kernel APIs to claim otherwise.

## Detection

On 64 GiB: warning 16, high 24, critical 32, emergency 40 GiB. Other capacities scale by 25%, 37.5%, 50%, 62.5%; the dedicated Thresholds tab offers both intervention values, recommends them from physical RAM on first use, and accepts per-application overrides. The emergency threshold must exceed the pause threshold. Warning and high levels stay below pause. Footprints are summed only for the selected application's verified components when evaluating automatic intervention. This sum is an accounting signal, not independent physical RAM usage.

Growth windows are 10, 30 and 60 seconds. A gap over six seconds discards history. A membership change resets the aggregate detector to avoid treating a newly discovered process as allocation growth. The chosen culprit must itself show positive growth over ten seconds; large stable siblings are not selected. Normal/warning sampling is configurable at one, two (default), or five seconds, high/critical sampling every second, discovery every five seconds. Histories are bounded to 301 samples per live process/application.

Critical pause requires three consecutive abnormal samples and a healthy recovery service. Emergency termination requires an enabled emergency policy, emergency footprint, confirmed growth and a verified individual culprit; it bypasses pause and recovery readiness. Critical system pressure alone never authorizes a signal. A stable large footprint alone does not authorize a signal. The 60-second rule detects slower sustained growth. A ten-second evidence window means an instantaneous allocation burst may outrun the guard.

## Freeze protocol

1. Hold the exclusive lease lock; reject an already stopped process.
2. Revalidate identity and independently check recovery health.
3. Publish the prepared identity and deadline in private, named POSIX shared memory before SIGSTOP. If the bounded 256 KiB record cannot be published, do not stop the process.
4. Send SIGSTOP and mark the record frozen. Two slots with an atomic active index keep the previous complete record readable if the writing process dies in the middle of a copy. All readers/writers hold the same per-user lock.
5. Renew the 30-second recovery lease in RAM only. Shared memory survives helper and UI restarts. A system reboot removes both the target processes and their leases; a disk record would not recover additional running processes. An old file-based lease is imported under the lock.

The default two-minute timeout can be changed to five minutes or disabled per app. Only the original guard may execute a live timeout. The default **Allow resuming paused processes** setting is off: the incident UI offers only confirmed force-end, there are no resume notification actions, and the agent rejects even stale resume/hold/normal-exit requests. Disabling protection or removing the app while an owned process is paused requires resolving the pause first. A guard interruption cancels the old countdown without resuming the process. The new agent can still show and end it.

When resuming is enabled, the user may resume, keep paused without a countdown, request normal exit, or force-end. Recovery can also release an orphaned/expired lease. A normal exit to a stopped target queues SIGTERM before SIGCONT; handlers may still decline to exit. There is no automatic resume merely because memory pressure falls.

## Resource and disk budget

- Samples, graphs, process lists, heartbeats, countdowns and pause/renewal records stay in RAM. Sampling faster does not increase the app's recurring disk writes.
- Rare ordinary diagnostic events append one JSON line without forcing a disk flush. Incomplete trailing records are discarded at the next append. The log holds at most 1,500 events, compacting in batches when full. The default retention is three days; hourly expiry writes only when something expires. UI snapshots contain at most the latest 200 events.
- A small independent, durable intervention journal (at most 256 entries, ten-minute safety window) preserves cooldowns and repeated-intervention protection when the user clears diagnostics. Settings are saved on actual changes. Exports are written only when requested.
- The collection cap is 512 tracked processes, 32 app policies, and 301 samples per live series. Stale histories and signature caches are evicted. Signatures are checked again before sending any signal.
- The two helpers use explicit autorelease pools. Above its 128 MiB footprint budget the agent handles its outstanding pauses under the selected resume policy and exits for launchd restart; the recovery helper has a 64 MiB budget. With a hidden menu item, closing the main window lets the UI exit without stopping either helper.
- The UI shows a switch change immediately while serializing updates to the guard. Old sampling replies cannot overwrite an in-flight preference.
- The watcher reads no environment, command arguments, source files or conversation contents. Diagnostic export omits executable paths and signing details.

System memory percentage is an estimate from active/inactive/wired/compressed counters minus reclaimable/external pages, bounded by physical memory. Swap usage and swap-out rate are distinct measurements. No swap cleanup or cache purging occurs.
