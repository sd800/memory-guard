import Foundation
import CGuard
import Darwin

public final class Store {
    private static let safetyKinds: Set<String> = ["frozen", "resumed", "recovered", "terminated", "emergencyKilled", "timeoutKilled", "signalFailed"]
    public let root: URL
    private let temporaryNamespace: Bool
    public init(root: URL? = nil) throws {
        temporaryNamespace = root != nil
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MemoryGuard", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let info = try FileManager.default.attributesOfItem(atPath: self.root.path)
        guard (info[.type] as? FileAttributeType) == .typeDirectory,
              (info[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw GuardError.failure("unsafeStorage") }
        if (info[.posixPermissions] as? NSNumber)?.intValue != 0o700 { chmod(self.root.path, 0o700) }
    }
    deinit { if temporaryNamespace { clearHeartbeat("agent-heartbeat.json"); clearHeartbeat("recovery-heartbeat.json"); clearHeartbeat("paused-processes") } }
    private func heartbeatName(_ name: String) -> String {
        let hash = (root.path + name).utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return "/mg\(getuid())-\(String(hash, radix: 16))"
    }
    public func url(_ name: String) -> URL { root.appendingPathComponent(name) }
    public func read<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let data = try Data(contentsOf: url(name), options: .mappedIfSafe)
        guard data.count <= 8 * 1024 * 1024 else { throw GuardError.failure("storageLimit") }
        return try JSONDecoder().decode(type, from: data)
    }
    public func write<T: Encodable>(_ value: T, to name: String) throws { try writeData(JSONEncoder().encode(value), to: name) }
    /// Kernel shared memory: no heartbeat files, disk writes, or fsync in steady state.
    public func heartbeat(_ value: Heartbeat, to name: String) throws {
        var raw = MGHeartbeat(); raw.pid = value.token.pid; raw.uid = value.token.uid
        raw.start_seconds = value.token.startSeconds; raw.start_microseconds = value.token.startMicroseconds; raw.uptime = value.uptime
        _ = withUnsafeMutablePointer(to: &raw.path) { buffer in
            buffer.withMemoryRebound(to: CChar.self, capacity: 4096) { pointer in value.token.path.withCString { strlcpy(pointer, $0, 4096) } }
        }
        let result = mg_heartbeat_write(heartbeatName(name), &raw)
        if result != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
    }
    public func readHeartbeat(_ name: String) throws -> Heartbeat {
        var raw = MGHeartbeat(); let result = mg_heartbeat_read(heartbeatName(name), &raw)
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
        let path = withUnsafePointer(to: &raw.path) { $0.withMemoryRebound(to: CChar.self, capacity: 4096) { String(cString: $0) } }
        return Heartbeat(token: ProcessToken(pid: raw.pid, uid: raw.uid, startSeconds: raw.start_seconds, startMicroseconds: raw.start_microseconds, path: path), uptime: raw.uptime)
    }
    public func clearHeartbeat(_ name: String) { mg_heartbeat_remove(heartbeatName(name)) }
    public func writeData(_ data: Data, to name: String) throws {
        let result = data.withUnsafeBytes { mg_atomic_write(url(name).path, $0.baseAddress, data.count) }
        if result != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
    }
    public func remove(_ name: String) { try? FileManager.default.removeItem(at: url(name)) }
    public func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url(name).path) }
    public func locked<T>(_ name: String, _ body: () throws -> T) throws -> T {
        let fd = open(url(name).path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return try body()
    }
    public func leaseTransaction<T>(_ body: (inout [FreezeLease]) throws -> T) throws -> T {
        try locked("leases.lock") {
            var leases = try readLeases()
            return try body(&leases)
        }
    }
    public func leases() throws -> [FreezeLease] {
        try locked("leases.lock") { try readLeases() }
    }
    // Access only while holding leases.lock. Named shared memory survives either helper's
    // exit. Reboot destroys both the records and the processes to which they refer.
    private func readLeases() throws -> [FreezeLease] {
        let name = heartbeatName("paused-processes")
        var count = 0
        let status = mg_leases_read(name, nil, 0, &count)
        if status == ENOENT {
            guard exists("leases.json") else { return [] }
            let legacy = try read("leases.json", as: [FreezeLease].self)
            try saveLeases(legacy)
            return legacy
        }
        guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(status)) }
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { mg_leases_read(name, $0.baseAddress, $0.count, &count) }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
        return try JSONDecoder().decode([FreezeLease].self, from: data)
    }
    func saveLeases(_ leases: [FreezeLease]) throws {
        let name = heartbeatName("paused-processes")
        let data = leases.isEmpty ? Data() : try JSONEncoder().encode(leases)
        let code = data.withUnsafeBytes { mg_leases_write(name, $0.baseAddress, $0.count) }
        guard code == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        if exists("leases.json") { try FileManager.default.removeItem(at: url("leases.json")) }
    }
    private let eventFile = "events.jsonl"
    public var eventModificationDate: Date? {
        let name = exists(eventFile) ? eventFile : "events.json"
        return (try? FileManager.default.attributesOfItem(atPath: url(name).path)[.modificationDate]) as? Date
    }
    // The append-only diagnostic log is best effort. The independently synced intervention
    // journal and freeze journal never rely on a buffered diagnostic write.
    private func eventData() throws -> Data {
        let size = try FileManager.default.attributesOfItem(atPath: url(eventFile).path)[.size] as? NSNumber
        guard let size, size.intValue <= 8 * 1024 * 1024 else { throw GuardError.failure("storageLimit") }
        return try Data(contentsOf: url(eventFile), options: .mappedIfSafe)
    }
    private func eventsUnlocked() throws -> [GuardEvent] {
        guard exists(eventFile) else { return exists("events.json") ? try read("events.json", as: [GuardEvent].self) : [] }
        return try eventData().split(separator: 10).compactMap { try? JSONDecoder().decode(GuardEvent.self, from: Data($0)) }
    }
    public func events() throws -> [GuardEvent] { try locked("events.lock") { try eventsUnlocked() } }
    private func compact(_ events: [GuardEvent]) throws {
        if exists("events.json"), !exists("interventions.json") {
            let history = safetyHistory()
            if !history.isEmpty { try write(history, to: "interventions.json") }
        }
        let encoder = JSONEncoder(); var lines = Data()
        for event in events { lines.append(try encoder.encode(event)); lines.append(10) }
        try writeData(lines, to: eventFile)
        if exists("events.json") { try FileManager.default.removeItem(at: url("events.json")) }
    }
    private func append(_ event: GuardEvent) throws {
        var line = try JSONEncoder().encode(event); line.append(10)
        let fd = open(url(eventFile).path, O_CREAT | O_APPEND | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }; defer { close(fd) }
        try line.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }; offset += n
            }
        }
    }
    public func event(_ event: GuardEvent, retention: Int = 3) {
        try? locked("events.lock") {
            if Self.safetyKinds.contains(event.kind) {
                try locked("interventions.lock") {
                    var journal = safetyHistory()
                    journal.append(event)
                    try write(Array(journal.suffix(256)), to: "interventions.json")
                }
            }
            let legacy = exists("events.json")
            let data = exists(eventFile) ? try eventData() : Data()
            let partial = !data.isEmpty && data.last != 10
            // Reserve space in batches; the 1,501st event does not trigger a full rewrite of each successor.
            if legacy || partial || data.reduce(0, { $0 + ($1 == 10 ? 1 : 0) }) >= 1500 {
                let cutoff = Date().addingTimeInterval(-Double(retention) * 86400)
                let kept = try eventsUnlocked().filter { $0.date >= cutoff }
                try compact(Array(kept.suffix(legacy ? 1499 : 1250)) + [event])
            } else { try append(event) }
        }
    }
    public func safetyHistory() -> [GuardEvent] {
        // Older installations only had events.json. New installations record safety actions separately.
        let events = (try? read("interventions.json", as: [GuardEvent].self)) ?? (try? read("events.json", as: [GuardEvent].self)) ?? []
        return Array(events.filter { Self.safetyKinds.contains($0.kind) && Date().timeIntervalSince($0.date) < 600 }.suffix(256))
    }
    public func clearDiagnostics() throws {
        try locked("events.lock") {
            if exists("events.json"), !exists("interventions.json") {
                try locked("interventions.lock") {
                    let history = safetyHistory()
                    if !history.isEmpty { try write(history, to: "interventions.json") }
                }
            }
            for name in [eventFile, "events.json"] where exists(name) { try FileManager.default.removeItem(at: url(name)) }
        }
    }
    public func pruneEvents(retention: Int) {
        try? locked("events.lock") {
            guard exists(eventFile) || exists("events.json") else { return }
            let events = try eventsUnlocked()
            let cutoff = Date().addingTimeInterval(-Double(retention) * 86400)
            let kept = Array(events.filter { $0.date >= cutoff }.suffix(1500))
            if kept.count != events.count || exists("events.json") {
                try compact(kept)
            }
        }
    }
}
public final class InstanceLock {
    private let fd: Int32
    public init(store: Store, name: String) throws {
        fd = open(store.url(name).path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { if fd >= 0 { close(fd) }; throw GuardError.failure("alreadyRunning") }
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
}
public struct Heartbeat: Codable {
    public var token: ProcessToken, uptime: Double
    public init(token: ProcessToken, uptime: Double) { self.token = token; self.uptime = uptime }
}
