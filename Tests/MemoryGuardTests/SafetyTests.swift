import XCTest
import Darwin
@testable import MemoryGuardKit

final class SafetyTests: XCTestCase {
    func token(pid: Int32 = 101, start: UInt64 = 1, uid: UInt32 = 501) -> ProcessToken {
        ProcessToken(pid: pid, uid: uid, startSeconds: start, startMicroseconds: 2, path: "/Test.app/Contents/MacOS/Test")
    }
    func testPIDReuseAndDifferentUserRejected() {
        let saved = token()
        XCTAssertFalse(SafetyRules.maySignal(saved: saved, current: token(start: 2), ownPID: 100, ownUID: 501))
        XCTAssertFalse(SafetyRules.maySignal(saved: saved, current: saved, ownPID: 100, ownUID: 502))
        XCTAssertFalse(SafetyRules.maySignal(saved: saved, current: saved, ownPID: 101, ownUID: 501))
        XCTAssertFalse(SafetyRules.maySignal(saved: saved, current: nil, ownPID: 100, ownUID: 501))
        XCTAssertTrue(SafetyRules.maySignal(saved: saved, current: saved, ownPID: 100, ownUID: 501))
    }
    func testBundleBoundaryRejectsShellAndSimilarNames() {
        XCTAssertTrue(SafetyRules.within("/Applications/Test.app/Contents/Frameworks/Helper", bundle: "/Applications/Test.app"))
        XCTAssertFalse(SafetyRules.within("/Applications/Test.app.evil/Contents/MacOS/Test", bundle: "/Applications/Test.app"))
        XCTAssertFalse(SafetyRules.within("/bin/zsh", bundle: "/Applications/Test.app"))
        XCTAssertFalse(SafetyRules.within("/usr/local/bin/node", bundle: "/Applications/Test.app"))
    }
    func testDeadlineIsIndependentOfRecoveryLeaseAndRequiresCurrentPolicy() {
        var p = DetectionTests().policy()
        var lease = FreezeLease(appID: p.id, process: token(), signingHash: "hash", owner: token(pid: 100), now: 0, timeout: 120)
        XCTAssertEqual(lease.expires, 30); XCTAssertEqual(lease.deadline, 120)
        XCTAssertFalse(SafetyRules.timeoutDue(lease: lease, now: 119, policy: p, guardEnabled: true))
        XCTAssertTrue(SafetyRules.timeoutDue(lease: lease, now: 120, policy: p, guardEnabled: true))
        XCTAssertFalse(SafetyRules.timeoutDue(lease: lease, now: 150, policy: nil, guardEnabled: true))
        XCTAssertFalse(SafetyRules.timeoutDue(lease: lease, now: 150, policy: p, guardEnabled: false))
        p.timeoutSeconds = 0
        XCTAssertFalse(SafetyRules.timeoutDue(lease: lease, now: 150, policy: p, guardEnabled: true))
        p.timeoutSeconds = 120; lease.timeoutCancelled = true
        XCTAssertFalse(SafetyRules.timeoutDue(lease: lease, now: 150, policy: p, guardEnabled: true))
    }
    func testUnsignedAppCannotUseProtection() {
        var s = Settings(); var p = DetectionTests().policy(); p.identity.trusted = false; s.apps = [p]
        XCTAssertFalse(s.valid)
        p.mode = .monitor; p.emergencyKill = false; s.apps = [p]; XCTAssertTrue(s.valid)
    }
    func testSettingsMigrationPreservesExistingPolicyAndDefaultsNewVisibilityOff() throws {
        let old = Data(#"{"apps":[],"guardEnabled":true,"showPercentage":true,"startAtLogin":false,"retentionDays":5}"#.utf8)
        let settings = try JSONDecoder().decode(Settings.self, from: old)
        XCTAssertFalse(settings.showInMenuBar); XCTAssertTrue(settings.showPercentage); XCTAssertEqual(settings.retentionDays, 5)
        XCTAssertEqual(settings.language, .system)
        XCTAssertEqual(settings.samplingSeconds, 2)
        var invalid = settings; invalid.samplingSeconds = 60; XCTAssertFalse(invalid.valid)
    }
    func testMissingPercentagePrefersVisibleNumberButRespectsSavedOptOut() throws {
        let decoder = JSONDecoder()
        let migrated = try decoder.decode(Settings.self, from: Data("{}".utf8))
        XCTAssertFalse(migrated.showInMenuBar)
        XCTAssertTrue(migrated.showPercentage)
        let optedOut = try decoder.decode(Settings.self, from: Data(#"{"showPercentage":false}"#.utf8))
        XCTAssertFalse(optedOut.showPercentage)
    }
    func testFullQuitRefusesAnOutstandingPauseBeforeStoppingEitherHelper() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(root: dir)
        let lease = FreezeLease(appID: "test", process: token(), signingHash: "fixture", owner: token(pid: 102), now: 0, timeout: 120)
        try store.leaseTransaction { _ in try store.saveLeases([lease]) }
        XCTAssertThrowsError(try IPC.stopServices(store: store) { _ in XCTFail("Must preserve both helpers"); return 0 }) {
            XCTAssertEqual(($0 as? GuardError)?.errorDescription, "quitWithPausedProcesses")
        }
        XCTAssertEqual(try store.leases(), [lease])
        try store.leaseTransaction { _ in try store.saveLeases([]) }
        var jobs: [String] = []
        try IPC.stopServices(store: store) { args in jobs.append(args[1]); return 0 }
        XCTAssertEqual(jobs, ["gui/\(getuid())/local.memoryguard.agent", "gui/\(getuid())/local.memoryguard.recovery"])
    }
    func testAtomicJournalRoundtripAndCorruptionFailsClosed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(root: dir)
        let lease = FreezeLease(appID: "test", process: token(), signingHash: "hash", owner: token(pid: 100), now: 0, timeout: 120)
        try store.leaseTransaction { records in records.append(lease); try store.write(records, to: "leases.json") }
        XCTAssertEqual(try store.leases().count, 1)
        try store.leaseTransaction { _ in try store.saveLeases([]) }
        try Data("broken".utf8).write(to: store.url("leases.json"))
        XCTAssertThrowsError(try store.leases())
    }
    func testEventsBoundedAndExpire() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }; let store = try Store(root: dir)
        var old = GuardEvent(appID: "test", kind: "old"); old.date = Date().addingTimeInterval(-40 * 86400)
        try store.write(Array(repeating: GuardEvent(appID: "test", kind: "test"), count: 1500) + [old], to: "events.json")
        store.event(GuardEvent(appID: "test", kind: "new"))
        let events = try store.events()
        XCTAssertEqual(events.count, 1500); XCTAssertEqual(events.last?.kind, "new"); XCTAssertFalse(events.contains { $0.kind == "old" })
    }
    func testClearingDiagnosticsPreservesSafetyJournalAndFreezeLeases() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }; let store = try Store(root: dir)
        let lease = FreezeLease(appID: "test", process: token(), signingHash: "hash", owner: token(pid: 100), now: 0, timeout: 120)
        try store.write([lease], to: "leases.json")
        store.event(GuardEvent(appID: "test", kind: "frozen", pid: 101, detail: token().key))
        try store.clearDiagnostics()
        XCTAssertTrue(try store.events().isEmpty)
        XCTAssertEqual(store.safetyHistory().count, 1)
        XCTAssertEqual(try store.leases().first?.id, lease.id)
    }
    func testHeartbeatReusesKernelMemoryWithoutCreatingDiskFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }; let store = try Store(root: dir)
        for i in 0..<100 {
            try store.heartbeat(Heartbeat(token: token(), uptime: Double(i)), to: "agent-heartbeat.json")
            XCTAssertEqual(try store.readHeartbeat("agent-heartbeat.json").uptime, Double(i))
        }
        XCTAssertFalse(store.exists("agent-heartbeat.json"))
        store.clearHeartbeat("agent-heartbeat.json")
        XCTAssertThrowsError(try store.readHeartbeat("agent-heartbeat.json"))
    }
    func testPartialDiagnosticAppendDoesNotLosePreviousEventsOrSafetyState() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }; let store = try Store(root: dir)
        store.event(GuardEvent(appID: "test", kind: "frozen"))
        let handle = try FileHandle(forWritingTo: store.url("events.jsonl"))
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{".utf8)); try handle.close()
        store.event(GuardEvent(appID: "test", kind: "warning"))
        XCTAssertEqual(try store.events().map(\.kind), ["frozen", "warning"])
        XCTAssertEqual(store.safetyHistory().map(\.kind), ["frozen"])
    }
}
