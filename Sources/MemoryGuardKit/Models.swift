import Foundation

public let GiB = 1_073_741_824.0
public let MiB = 1_048_576.0
public enum BuildInfo {
    public static let version = "26.11.1"
    public static let build = "6"
    public static let appID = "local.memoryguard.app"
}
public enum Mode: String, Codable, CaseIterable { case monitor, alert, protect }
public enum AppLanguage: String, Codable, CaseIterable { case system, english, chinese }
public enum Level: Int, Codable, Comparable {
    case normal, warning, high, critical, emergency
    public static func < (l: Level, r: Level) -> Bool { l.rawValue < r.rawValue }
}
public enum Pressure: String, Codable { case normal, warning, critical, unknown }
public struct Thresholds: Codable, Equatable {
    public var warning: Double, high: Double, critical: Double, emergency: Double
    public init(memory: Double) {
        warning = memory * 0.25; high = memory * 0.375
        critical = memory * 0.5; emergency = memory * 0.625
    }
    public var valid: Bool {
        [warning, high, critical, emergency].allSatisfy { $0.isFinite && $0 >= 256 * MiB } &&
        warning < high && high < critical && critical < emergency
    }
    public func level(_ bytes: Double) -> Level {
        if bytes >= emergency { return .emergency }; if bytes >= critical { return .critical }
        if bytes >= high { return .high }; if bytes >= warning { return .warning }; return .normal
    }
}
public struct AppIdentity: Codable, Equatable {
    public var name: String, bundleID: String, path: String
    public var teamID: String?, requirement: String?
    public var trusted: Bool
    public init(name: String, bundleID: String, path: String, teamID: String?, requirement: String?, trusted: Bool) {
        self.name = name; self.bundleID = bundleID; self.path = path
        self.teamID = teamID; self.requirement = requirement; self.trusted = trusted
    }
}
public struct AppPolicy: Codable, Identifiable, Equatable {
    public var id: String { identity.bundleID }
    public var displayName: String { id == "com.openai.codex" && identity.teamID == "2DC432GLL2" ? "Codex" : identity.name }
    public var identity: AppIdentity
    public var enabled = true
    public var mode: Mode = .alert
    public var emergencyKill = false
    public var timeoutSeconds = 0
    public var customThresholds: Thresholds?
    public init(identity: AppIdentity, codexPreset: Bool = false) {
        self.identity = identity
        if codexPreset && identity.trusted { mode = .protect; emergencyKill = true; timeoutSeconds = 120 }
    }
}
public struct Settings: Codable, Equatable {
    public var apps: [AppPolicy] = []
    public var allowResume = false
    public var guardEnabled = true
    public var showInMenuBar = false
    public var showPercentage = true
    public var startAtLogin = false
    public var language: AppLanguage = .system
    public var samplingSeconds = 2
    public var retentionDays = 3
    public init() {}
    private enum CodingKeys: String, CodingKey { case apps, allowResume, guardEnabled, showInMenuBar, showPercentage, startAtLogin, language, samplingSeconds, retentionDays }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        apps = try values.decodeIfPresent([AppPolicy].self, forKey: .apps) ?? []
        allowResume = try values.decodeIfPresent(Bool.self, forKey: .allowResume) ?? false
        guardEnabled = try values.decodeIfPresent(Bool.self, forKey: .guardEnabled) ?? true
        showInMenuBar = try values.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? false
        showPercentage = try values.decodeIfPresent(Bool.self, forKey: .showPercentage) ?? true
        startAtLogin = try values.decodeIfPresent(Bool.self, forKey: .startAtLogin) ?? false
        language = try values.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        samplingSeconds = try values.decodeIfPresent(Int.self, forKey: .samplingSeconds) ?? 2
        retentionDays = try values.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 3
    }
    public var valid: Bool {
        apps.count <= 32 && Set(apps.map(\.id)).count == apps.count && (1...90).contains(retentionDays) && [1, 2, 5].contains(samplingSeconds) &&
        apps.allSatisfy { [0, 120, 300].contains($0.timeoutSeconds) && ($0.customThresholds?.valid ?? true) &&
            ($0.identity.trusted || ($0.mode != .protect && !$0.emergencyKill)) }
    }
}
public struct ProcessToken: Codable, Hashable {
    public var pid: Int32, uid: UInt32
    public var startSeconds: UInt64, startMicroseconds: UInt64
    public var path: String
    public init(pid: Int32, uid: UInt32, startSeconds: UInt64, startMicroseconds: UInt64, path: String) {
        self.pid = pid; self.uid = uid; self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds; self.path = path
    }
    public var key: String { "\(pid):\(startSeconds):\(startMicroseconds)" }
}
public struct ProcessReading: Codable, Identifiable {
    public var id: String { token.key }
    public var token: ProcessToken
    public var footprint: Double
    public var verified: Bool
    public var stopped: Bool
    public var signingHash: String?
    public init(token: ProcessToken, footprint: Double, verified: Bool, stopped: Bool, signingHash: String?) {
        self.token = token; self.footprint = footprint; self.verified = verified
        self.stopped = stopped; self.signingHash = signingHash
    }
}
public struct Sample: Codable, Sendable {
    public var time: Double, bytes: Double
    public init(time: Double, bytes: Double) { self.time = time; self.bytes = bytes }
}
public struct SystemReading: Codable {
    public var physical = 0.0, used = 0.0, swapUsed = 0.0, swapoutRate = 0.0
    public var pressure: Pressure = .unknown
    public var valid = false
    public init() {}
    public var percentage: Int { physical > 0 ? Int((100 * used / physical).rounded()) : 0 }
}
public struct AppSnapshot: Codable, Identifiable {
    public var id: String
    public var processes: [ProcessReading] = []
    public var footprint = 0.0, growth30 = 0.0
    public var level: Level = .normal
    public var history: [Sample] = []
    public var error: String?
    public init(id: String) { self.id = id }
}
public struct GuardEvent: Codable, Identifiable {
    public var id = UUID().uuidString
    public var date = Date()
    public var appID: String
    public var kind: String
    public var pid: Int32?
    public var bytes: Double?
    public var detail: String?
    public init(appID: String, kind: String, pid: Int32? = nil, bytes: Double? = nil, detail: String? = nil) {
        self.appID = appID; self.kind = kind; self.pid = pid; self.bytes = bytes; self.detail = detail
    }
}
public enum LeasePhase: String, Codable { case prepared, frozen }
public struct FreezeLease: Codable, Identifiable, Equatable {
    public var id = UUID().uuidString
    public var appID: String, process: ProcessToken, signingHash: String
    public var owner: ProcessToken
    public var phase: LeasePhase = .prepared
    public var created = Date()
    public var expires: Double
    public var deadline: Double?
    public var timeoutCancelled = false
    public init(appID: String, process: ProcessToken, signingHash: String, owner: ProcessToken, now: Double, timeout: Int) {
        self.appID = appID; self.process = process; self.signingHash = signingHash; self.owner = owner
        self.expires = now + 30; self.deadline = timeout > 0 ? now + Double(timeout) : nil
    }
}
public struct Snapshot: Codable {
    public var settings = Settings()
    public var system = SystemReading()
    public var apps: [AppSnapshot] = []
    public var leases: [FreezeLease] = []
    public var events: [GuardEvent] = []
    public var recoveryReady = false
    public var uptime = 0.0
    public var error: String?
    public init() {}
}
public struct WireRequest: Codable {
    public var action: String
    public var data: Data?
    public var value: String?
    public init(_ action: String, data: Data? = nil, value: String? = nil) {
        self.action = action; self.data = data; self.value = value
    }
}
public struct WireReply: Codable {
    public var snapshot: Snapshot?
    public var error: String?
    public init(snapshot: Snapshot? = nil, error: String? = nil) { self.snapshot = snapshot; self.error = error }
}
public enum GuardError: Error, LocalizedError {
    case failure(String)
    public var errorDescription: String? { if case let .failure(message) = self { return message }; return nil }
}
