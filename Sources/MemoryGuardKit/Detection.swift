import Foundation

/// Bounded and gap-aware; no growth estimate spans sleep, restart, or a missed interval.
public struct History {
    public private(set) var samples: [Sample] = []
    public init() {}
    public mutating func append(_ sample: Sample) {
        if let last = samples.last, sample.time <= last.time || sample.time - last.time > 6 { samples.removeAll(keepingCapacity: true) }
        samples.append(sample)
        samples.removeAll { sample.time - $0.time > 300 }
        if samples.count > 301 { samples.removeFirst(samples.count - 301) }
    }
    public func delta(seconds: Double) -> Double? {
        guard let last = samples.last,
              let first = samples.last(where: { last.time - $0.time >= seconds }),
              last.time - first.time <= seconds + 3 else { return nil }
        return last.bytes - first.bytes
    }
    public func rate(seconds: Double) -> Double? {
        guard let last = samples.last,
              let first = samples.last(where: { last.time - $0.time >= seconds }),
              last.time - first.time <= seconds + 3 else { return nil }
        return (last.bytes - first.bytes) / (last.time - first.time)
    }
}
public enum Decision: Equatable { case none, freeze, kill }
public struct Detector {
    public private(set) var history = History()
    public private(set) var level: Level = .normal
    private var consecutive = 0
    private var lowerSince: Double?
    private var lastTime: Double?
    public init() {}
    public mutating func evaluate(bytes: Double, time: Double, thresholds: Thresholds, pressure: Pressure,
                                  policy: AppPolicy, recoveryReady: Bool, eligible: Bool, cooldown: Bool) -> Decision {
        if let lastTime, time - lastTime > 6 || time <= lastTime { consecutive = 0; lowerSince = nil }
        lastTime = time
        history.append(Sample(time: time, bytes: bytes))
        let raw = thresholds.level(bytes)
        if raw >= level { level = raw; lowerSince = nil }
        else {
            let boundary: Double
            switch level {
            case .emergency: boundary = thresholds.emergency
            case .critical: boundary = thresholds.critical
            case .high: boundary = thresholds.high
            case .warning: boundary = thresholds.warning
            case .normal: boundary = 0
            }
            if bytes < boundary * 0.85 {
                if lowerSince == nil { lowerSince = time }
                if time - (lowerSince ?? time) >= 10 { level = raw; lowerSince = nil }
            } else { lowerSince = nil }
        }
        // Scale growth rules with RAM while retaining useful bounds on small / large Macs.
        let scale = min(4, max(0.25, thresholds.emergency / (40 * GiB)))
        let fast = (history.rate(seconds: 10) ?? 0) > 256 * MiB * scale
        let burst = (history.delta(seconds: 30) ?? 0) > 4 * GiB * scale
        let slow = (history.delta(seconds: 60) ?? 0) > 2 * GiB * scale
        let pressured = pressure == .critical && (history.rate(seconds: 10) ?? 0) > 32 * MiB * scale
        let anomaly = fast || burst || slow || pressured
        consecutive = anomaly ? consecutive + 1 : 0
        guard policy.enabled, policy.mode == .protect, policy.identity.trusted, eligible, !cooldown else { return .none }
        // Emergency has its own authorization and never waits for the freeze timeout.
        if raw == .emergency && anomaly && policy.emergencyKill { return .kill }
        if raw >= .critical && consecutive >= 3 && recoveryReady { return .freeze }
        return .none
    }
}

public enum SafetyRules {
    public static func maySignal(saved: ProcessToken, current: ProcessToken?, ownPID: Int32, ownUID: UInt32) -> Bool {
        guard let current else { return false }
        return saved == current && current.pid > 1 && current.pid != ownPID && current.uid == ownUID
    }
    public static func within(_ executable: String, bundle: String) -> Bool {
        let root = URL(fileURLWithPath: bundle).resolvingSymlinksInPath().standardized.path
        let path = URL(fileURLWithPath: executable).resolvingSymlinksInPath().standardized.path
        return path.hasPrefix(root + "/Contents/")
    }
    public static func timeoutDue(lease: FreezeLease, now: Double, policy: AppPolicy?, guardEnabled: Bool) -> Bool {
        guard guardEnabled, let policy, policy.enabled, policy.mode == .protect, policy.timeoutSeconds > 0,
              !lease.timeoutCancelled, let deadline = lease.deadline else { return false }
        return now >= deadline
    }
}
