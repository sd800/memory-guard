import Foundation
import AppKit
import Darwin

public final class GuardEngine {
    public let store: Store
    public private(set) var settings: Settings
    public private(set) var snapshot = Snapshot()
    private let owner: ProcessToken
    private let discovery = ProcessDiscovery()
    private var detectors: [String: Detector] = [:]
    private var histories: [String: History] = [:]
    private var membership: [String: Set<String>] = [:]
    private var cooldown: [String: Double] = [:]
    private var lastDiscovery = -100.0
    private var lastTick = -100.0
    private var lastSwap: (Double, Double)?
    private var heartbeatTime: Double?
    private var lastPrune = -Double.infinity
    private var eventStamp: Date?
    private var safetyEvents: [GuardEvent] = []
    private var safetyStamp: Date?
    private var loadedSafetyHistory = false
    private var pressure: Pressure = .unknown
    private let pressureSource: DispatchSourceMemoryPressure
    public let queue: DispatchQueue
    public init(store: Store, queue: DispatchQueue) throws {
        self.store = store; self.queue = queue
        if store.exists("settings.json") { settings = try store.read("settings.json", as: Settings.self) }
        else { settings = Settings(); try store.write(settings, to: "settings.json") }
        guard settings.valid, let owner = Processes.info(getpid())?.0 else { throw GuardError.failure("initializationFailed") }
        self.owner = owner
        pressureSource = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        pressureSource.setEventHandler { [weak self] in
            guard let self else { return }; let value = self.pressureSource.data
            self.pressure = value.contains(.critical) ? .critical : value.contains(.warning) ? .warning : .normal
        }
        pressureSource.resume()
        // Conservative restart: previously frozen targets are recovered before this agent can act again.
        for event in store.safetyHistory() where
            ["resumed", "recovered", "terminated", "emergencyKilled", "timeoutKilled", "signalFailed"].contains(event.kind) && Date().timeIntervalSince(event.date) < 600 {
            if let key = event.detail { cooldown[key] = Processes.now + max(0, 600 - Date().timeIntervalSince(event.date)) }
        }
    }
    deinit { pressureSource.cancel() }
    public func recoverBeforeMemoryRestart() {
        try? maintainLeases(now: Processes.now, interrupted: true)
        store.event(GuardEvent(appID: BuildInfo.appID, kind: "guardRestart"))
    }
    private func emit(_ kind: String, app: String, process: ProcessReading? = nil, detail: String? = nil) {
        store.event(GuardEvent(appID: app, kind: kind, pid: process?.token.pid, bytes: process?.footprint,
                               detail: detail ?? process?.token.key), retention: settings.retentionDays)
        if ["warning", "critical", "frozen", "emergencyKilled", "timeoutKilled", "signalFailed", "recoveryFailed"].contains(kind) { wakeInterface() }
    }
    private func wakeInterface() {
        let path = IPC.appExecutable()
        guard path.contains(".app/Contents/MacOS/") else { return }
        let url = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        DispatchQueue.main.async {
            guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == BuildInfo.appID }) else { return }
            let config = NSWorkspace.OpenConfiguration(); config.activates = false; config.arguments = ["--background"]
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
    }
    public func tick() {
        let now = Processes.now
        let interrupted = heartbeatTime.map { now - $0 > 6 || now < $0 } ?? false
        heartbeatTime = now
        do { try store.heartbeat(Heartbeat(token: owner, uptime: now), to: "agent-heartbeat.json") }
        catch { snapshot.error = "storageFailed"; return }
        snapshot.error = nil
        let recoveryReady = IPC.heartbeatHealthy("recovery-heartbeat.json", store: store)
        // launchd supervises each helper independently. Never spawn an unregistered duplicate.
        snapshot.recoveryReady = recoveryReady; snapshot.uptime = now; snapshot.settings = settings
        var system = Processes.system()
        let totalSwapouts = system.swapoutRate
        system.swapoutRate = lastSwap.map { now > $0.0 ? max(0, totalSwapouts - $0.1) / (now - $0.0) : 0 } ?? 0
        lastSwap = (now, totalSwapouts); system.pressure = pressure; snapshot.system = system
        do { try maintainLeases(now: now, interrupted: interrupted) }
        catch { snapshot.error = "recoveryFailed" }
        snapshot.leases = (try? store.leases()) ?? []
        if now - lastPrune > 3600 { store.pruneEvents(retention: settings.retentionDays); lastPrune = now }
        let stamp = store.eventModificationDate
        if stamp != eventStamp {
            eventStamp = stamp
            snapshot.events = Array(((try? store.events()) ?? []).suffix(200).reversed())
        }
        let currentSafetyStamp = (try? FileManager.default.attributesOfItem(atPath: store.url("interventions.json").path)[.modificationDate]) as? Date
        if currentSafetyStamp != safetyStamp || !loadedSafetyHistory { safetyStamp = currentSafetyStamp; safetyEvents = store.safetyHistory(); loadedSafetyHistory = true }
        for event in safetyEvents where ["recovered", "resumed", "terminated", "emergencyKilled", "timeoutKilled", "signalFailed"].contains(event.kind) {
            let remaining = 600 - Date().timeIntervalSince(event.date)
            if remaining > 0, let key = event.detail { cooldown[key] = now + remaining }
        }
        guard settings.guardEnabled, system.valid else {
            snapshot.apps = []; histories.removeAll(); detectors.removeAll(); membership.removeAll(); discovery.reset(); lastDiscovery = -100; return
        }
        let interval = snapshot.apps.contains { $0.level >= .high } ? 1.0 : Double(settings.samplingSeconds)
        guard now - lastTick >= interval - 0.1 else { return }; lastTick = now
        if now - lastDiscovery >= 5 {
            discovery.refresh(settings.apps); lastDiscovery = now
        }
        cooldown = cooldown.filter { $0.value > now }
        var appSnapshots: [AppSnapshot] = []
        var liveKeys = Set<String>()
        for policy in settings.apps where policy.enabled {
            let result = discovery.sample(policy.id)
            let readings = result.readings
            let keys = Set(readings.map(\.id)); liveKeys.formUnion(keys)
            if membership[policy.id] != keys { detectors[policy.id] = Detector(); membership[policy.id] = keys }
            for process in readings {
                histories[process.id, default: History()].append(Sample(time: now, bytes: process.footprint))
            }
            let trustedReadings = readings.filter(\.verified)
            let bytes = (policy.identity.trusted ? trustedReadings : readings).reduce(0) { $0 + $1.footprint }
            let thresholds = policy.customThresholds ?? Thresholds(memory: system.physical)
            // Attribute group growth to an individual before signaling. A large stable process is not a target.
            let candidates = trustedReadings.filter { !$0.stopped && (histories[$0.id]?.delta(seconds: 10) ?? 0) > 64 * MiB }
            let target = candidates.max { (histories[$0.id]?.delta(seconds: 10) ?? 0) < (histories[$1.id]?.delta(seconds: 10) ?? 0) }
            var detector = detectors[policy.id] ?? Detector()
            let previous = detector.level
            let repeatedInterventions = safetyEvents.filter { $0.appID == policy.id && ["frozen", "emergencyKilled", "timeoutKilled"].contains($0.kind) && Date().timeIntervalSince($0.date) < 600 }.count >= 3
            let decision = detector.evaluate(bytes: bytes, time: now, thresholds: thresholds, pressure: pressure,
                policy: policy, recoveryReady: recoveryReady, eligible: target != nil && result.failures == 0,
                cooldown: repeatedInterventions || (target.map { cooldown[$0.id] != nil } ?? false))
            detectors[policy.id] = detector
            var state = AppSnapshot(id: policy.id); state.processes = readings; state.footprint = bytes
            state.level = detector.level; state.growth30 = detector.history.delta(seconds: 30) ?? 0
            state.history = detector.history.samples
            if result.failures > 0 { state.error = "samplingDenied" }
            if discovery.limitedApps.contains(policy.id) { state.error = "trackingLimit" }
            if !policy.identity.trusted { state.error = "monitorOnlyIdentity" }
            if repeatedInterventions { state.error = "interventionLoop" }
            if previous < state.level && policy.mode != .monitor && state.level >= .warning {
                emit(state.level >= .critical ? "critical" : "warning", app: policy.id)
            }
            if let target, decision != .none {
                do {
                    if decision == .kill { try terminate(target, appID: policy.id, kind: "emergencyKilled") }
                    else { try freeze(target, policy: policy, now: now) }
                } catch {
                    cooldown[target.id] = now + 600; state.error = "signalFailed"
                    emit("signalFailed", app: policy.id, process: target)
                }
            }
            appSnapshots.append(state)
        }
        histories = histories.filter { liveKeys.contains($0.key) }
        let enabledIDs = Set(settings.apps.filter(\.enabled).map(\.id))
        detectors = detectors.filter { enabledIDs.contains($0.key) }; membership = membership.filter { enabledIDs.contains($0.key) }
        snapshot.apps = appSnapshots
    }
    private func validateTarget(_ process: ProcessReading, policy: AppPolicy) throws -> String {
        guard policy.enabled, policy.mode == .protect, policy.identity.trusted, process.verified,
              let hash = process.signingHash, let live = Signing.live(process.token.pid), live.team == policy.identity.teamID,
              SignalControl.validate(process.token, hash: hash) else { throw GuardError.failure("identityChanged") }
        return hash
    }
    func freeze(_ process: ProcessReading, policy: AppPolicy, now: Double) throws {
        let hash = try validateTarget(process, policy: policy)
        guard IPC.heartbeatHealthy("recovery-heartbeat.json", store: store) else { throw GuardError.failure("recoveryUnavailable") }
        try store.leaseTransaction { leases in
            guard !leases.contains(where: { $0.process == process.token }), Processes.info(process.token.pid)?.2 != 4 else { return }
            var lease = FreezeLease(appID: policy.id, process: process.token, signingHash: hash, owner: owner, now: now, timeout: policy.timeoutSeconds)
            leases.append(lease); try store.saveLeases(leases)
            do { try SignalControl.send(SIGSTOP, to: process.token, hash: hash) }
            catch { leases.removeAll { $0.id == lease.id }; try store.saveLeases(leases); throw error }
            lease.phase = .frozen; leases[leases.count - 1] = lease; try store.saveLeases(leases)
        }
        emit("frozen", app: policy.id, process: process)
    }
    func terminate(_ process: ProcessReading, appID: String, kind: String) throws {
        guard let policy = settings.apps.first(where: { $0.id == appID }) else { throw GuardError.failure("invalidApp") }
        let hash = try validateTarget(process, policy: policy)
        try SignalControl.send(SIGKILL, to: process.token, hash: hash)
        cooldown[process.id] = Processes.now + 600; emit(kind, app: appID, process: process)
    }
    func maintainLeases(now: Double, interrupted: Bool = false) throws {
        try store.leaseTransaction { leases in
            var updated: [FreezeLease] = []
            for var lease in leases {
                guard Processes.same(lease.process) else { continue }
                // Only this agent may renew its leases. Recovery owns orphaned leases.
                guard lease.owner == owner else {
                    if Processes.info(lease.process.pid)?.2 == 4 {
                        lease.deadline = nil; lease.timeoutCancelled = true; updated.append(lease)
                    }
                    continue
                }
                if lease.phase == .frozen && Processes.info(lease.process.pid)?.2 != 4 {
                    cooldown[lease.process.key] = now + 600
                    store.event(GuardEvent(appID: lease.appID, kind: "resumed", pid: lease.process.pid, detail: lease.process.key)); continue
                }
                let policy = settings.apps.first { $0.id == lease.appID }
                if interrupted || lease.phase != .frozen || !settings.guardEnabled || policy?.enabled != true || policy?.mode != .protect {
                    if !settings.allowResume {
                        lease.deadline = nil; lease.timeoutCancelled = true; updated.append(lease); continue
                    }
                    try SignalControl.send(SIGCONT, to: lease.process, hash: lease.signingHash)
                    cooldown[lease.process.key] = now + 600
                    store.event(GuardEvent(appID: lease.appID, kind: "resumed", pid: lease.process.pid, detail: lease.process.key)); continue
                }
                if SafetyRules.timeoutDue(lease: lease, now: now, policy: policy, guardEnabled: settings.guardEnabled) {
                    try SignalControl.send(SIGKILL, to: lease.process, hash: lease.signingHash)
                    cooldown[lease.process.key] = now + 600
                    store.event(GuardEvent(appID: lease.appID, kind: "timeoutKilled", pid: lease.process.pid, detail: lease.process.key)); wakeInterface(); continue
                }
                if lease.expires < now + 20 { lease.expires = now + 30 }
                updated.append(lease)
            }
            if updated != leases { try store.saveLeases(updated) }

        }
    }
    private func actOnLease(id: String, action: String) throws {
        try store.leaseTransaction { leases in
            guard let index = leases.firstIndex(where: { $0.id == id }) else { throw GuardError.failure("expiredAction") }
            let lease = leases[index]
            if action != "terminate" && !settings.allowResume { throw GuardError.failure("resumeDisabled") }
            if action == "hold" { leases[index].timeoutCancelled = true; leases[index].deadline = nil }
            else {
                if action == "resume" { try SignalControl.send(SIGCONT, to: lease.process, hash: lease.signingHash) }
                else if action == "terminate" { try SignalControl.send(SIGKILL, to: lease.process, hash: lease.signingHash) }
                else if action == "quit" {
                    try SignalControl.send(SIGTERM, to: lease.process, hash: lease.signingHash)
                    if Processes.same(lease.process) { try SignalControl.send(SIGCONT, to: lease.process, hash: lease.signingHash) }
                } else { throw GuardError.failure("invalidRequest") }
                leases.remove(at: index); cooldown[lease.process.key] = Processes.now + 600
            }
            try store.saveLeases(leases)
            store.event(GuardEvent(appID: lease.appID, kind: action == "resume" ? "resumed" : action == "terminate" ? "terminated" : action, pid: lease.process.pid, detail: lease.process.key))
        }
    }
    public func handle(_ request: WireRequest) -> WireReply {
        do {
            switch request.action {
            case "snapshot": break
            case "clearDiagnostics":
                try store.clearDiagnostics(); snapshot.events = []; eventStamp = nil
            case "add":
                guard let path = request.value else { throw GuardError.failure("invalidRequest") }
                let identity = try Signing.inspectApp(URL(fileURLWithPath: path))
                guard !settings.apps.contains(where: { $0.id == identity.bundleID }), settings.apps.count < 32 else { throw GuardError.failure("alreadyAdded") }
                let codex = identity.bundleID == "com.openai.codex" && identity.teamID == "2DC432GLL2"
                var next = settings; next.apps.append(AppPolicy(identity: identity, codexPreset: codex))
                try store.write(next, to: "settings.json"); settings = next; lastDiscovery = -100
            case "settings":
                guard let data = request.data else { throw GuardError.failure("invalidRequest") }
                let next = try JSONDecoder().decode(Settings.self, from: data)
                guard next.valid, next.apps.allSatisfy({ candidate in settings.apps.contains { $0.identity == candidate.identity } }) else { throw GuardError.failure("invalidSettings") }
                guard next != settings else { break }
                // Release first; a failed recovery must block removal or protection disable.
                let release = try store.leases().filter { lease in
                    let policy = next.apps.first { $0.id == lease.appID }
                    return !next.guardEnabled || policy == nil || policy?.enabled == false || policy?.mode != .protect
                }
                if !release.isEmpty && !next.allowResume { throw GuardError.failure("resumeDisabled") }
                for lease in release { try actOnLease(id: lease.id, action: "resume") }
                let previousSettings = settings
                try store.write(next, to: "settings.json"); settings = next
                if next.retentionDays != previousSettings.retentionDays { store.pruneEvents(retention: next.retentionDays) }
                // Changing a timeout cancels existing countdowns; it never retroactively shortens them.
                try store.leaseTransaction { leases in
                    let prior = leases
                    for i in leases.indices {
                        let nextTimeout = next.apps.first(where: { $0.id == leases[i].appID })?.timeoutSeconds
                        let previousTimeout = previousSettings.apps.first(where: { $0.id == leases[i].appID })?.timeoutSeconds
                        if nextTimeout == 0 || nextTimeout != previousTimeout { leases[i].deadline = nil; leases[i].timeoutCancelled = true }
                    }
                    if leases != prior { try store.saveLeases(leases) }
                }
                lastDiscovery = -100
            case "resume", "hold", "terminate", "quit":
                guard let id = request.value else { throw GuardError.failure("invalidRequest") }
                try actOnLease(id: id, action: request.action)
            default: throw GuardError.failure("invalidRequest")
            }
            snapshot.settings = settings; snapshot.leases = (try? store.leases()) ?? []
            return WireReply(snapshot: snapshot)
        } catch { return WireReply(error: (error as? GuardError)?.errorDescription ?? "operationFailed") }
    }
}

public final class RecoveryEngine {
    private let store: Store
    private let owner: ProcessToken
    public init(store: Store, supervise: Bool = true) throws {
        self.store = store
        guard let owner = Processes.info(getpid())?.0 else { throw GuardError.failure("initializationFailed") }; self.owner = owner
    }
    public func tick() {
        let now = Processes.now
        // A heartbeat is published only after the durable lease journal was successfully checked.
        do {
            try store.leaseTransaction { leases in
                var remaining: [FreezeLease] = []
                let allowResume = !leases.isEmpty && (try? store.read("settings.json", as: Settings.self).allowResume) == true
                for var lease in leases {
                    guard Processes.same(lease.process) else { continue }
                    let heartbeat = try? store.readHeartbeat("agent-heartbeat.json")
                    let healthy = heartbeat.map { $0.token == lease.owner && now >= $0.uptime && now - $0.uptime < 6 && Processes.same($0.token) } ?? false
                    if !healthy || now >= lease.expires || now < lease.expires - 35 {
                        if !allowResume {
                            // No SIGCONT and no inherited timeout. The UI can end this exact process after restart.
                            if Processes.info(lease.process.pid)?.2 == 4 {
                                lease.deadline = nil; lease.timeoutCancelled = true; remaining.append(lease)
                            }
                            continue
                        }
                        do {
                            try SignalControl.send(SIGCONT, to: lease.process, hash: lease.signingHash)
                            store.event(GuardEvent(appID: lease.appID, kind: "recovered", pid: lease.process.pid, detail: lease.process.key))
                        } catch {
                            remaining.append(lease)
                            // Preserve failed leases so they remain visible and can be retried.
                            if Int(now) % 30 < 2 { store.event(GuardEvent(appID: lease.appID, kind: "recoveryFailed", pid: lease.process.pid)) }
                        }
                    } else { remaining.append(lease) }
                }
                if remaining != leases { try store.saveLeases(remaining) }
            }
            try store.heartbeat(Heartbeat(token: owner, uptime: now), to: "recovery-heartbeat.json")
        } catch { store.clearHeartbeat("recovery-heartbeat.json"); return }
    }
}
