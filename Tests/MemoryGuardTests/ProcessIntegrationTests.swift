import XCTest
import Darwin
@testable import MemoryGuardKit

final class ProcessIntegrationTests: XCTestCase {
    private func fixture() throws -> (Process, ProcessToken, String) {
        let path = ProcessInfo.processInfo.environment["GUARD_PROBE_PATH"].map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/GuardProbe")
        guard FileManager.default.isExecutableFile(atPath: path.path) else { throw XCTSkip("Build GuardProbe before integration tests") }
        let task = Process(); task.executableURL = path; task.arguments = ["--fixture"]
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice; try task.run()
        Thread.sleep(forTimeInterval: 0.3)
        guard let info = Processes.info(task.processIdentifier, sample: true), let signing = Signing.live(task.processIdentifier) else {
            task.terminate(); throw XCTSkip("Process inspection unavailable in this sandbox")
        }
        return (task, info.0, signing.hash)
    }
    private func finish(_ process: Process, _ token: ProcessToken, _ hash: String) {
        if process.isRunning { try? SignalControl.send(SIGKILL, to: token, hash: hash); process.waitUntilExit() }
    }
    func testActualFreezeResumeAndStaleIdentityRejection() throws {
        let (task, token, hash) = try fixture(); defer { finish(task, token, hash) }
        var reused = token; reused.startMicroseconds += 1
        XCTAssertThrowsError(try SignalControl.send(SIGSTOP, to: reused, hash: hash))
        try SignalControl.send(SIGSTOP, to: token, hash: hash); Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(Processes.info(token.pid)?.2, 4)
        try SignalControl.send(SIGCONT, to: token, hash: hash); Thread.sleep(forTimeInterval: 0.1)
        XCTAssertNotEqual(Processes.info(token.pid)?.2, 4)
        XCTAssertGreaterThan(Processes.info(token.pid, sample: true)?.3 ?? 0, 0)
    }
    func testIndependentRecoveryResumesPreparedLeaseAfterOwnerDeath() throws {
        let (task, token, hash) = try fixture(); defer { finish(task, token, hash) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }; let store = try Store(root: dir)
        var deadOwner = token; deadOwner.startMicroseconds += 1
        var settings = Settings(); settings.allowResume = true; try store.write(settings, to: "settings.json")
        let lease = FreezeLease(appID: "fixture", process: token, signingHash: hash, owner: deadOwner, now: Processes.now, timeout: 120)
        try store.leaseTransaction { _ in try store.saveLeases([lease]) } // Prepared state also covers crash immediately after SIGSTOP.
        try SignalControl.send(SIGSTOP, to: token, hash: hash)
        let recovery = try RecoveryEngine(store: store, supervise: false); recovery.tick()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertNotEqual(Processes.info(token.pid)?.2, 4); XCTAssertTrue(try store.leases().isEmpty)
        XCTAssertEqual(try store.events().last?.kind, "recovered")
    }
    func testExpiredLeaseRecoversButHealthyLeaseRemainsPaused() throws {
        let (task, token, hash) = try fixture(); defer { finish(task, token, hash) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }; let store = try Store(root: dir)
        let owner = try XCTUnwrap(Processes.info(getpid())?.0)
        var settings = Settings(); settings.allowResume = true; try store.write(settings, to: "settings.json")
        var lease = FreezeLease(appID: "fixture", process: token, signingHash: hash, owner: owner, now: Processes.now, timeout: 120)
        try store.heartbeat(Heartbeat(token: owner, uptime: Processes.now), to: "agent-heartbeat.json")
        try store.leaseTransaction { _ in try store.saveLeases([lease]) }; try SignalControl.send(SIGSTOP, to: token, hash: hash)
        let recovery = try RecoveryEngine(store: store, supervise: false); recovery.tick()
        XCTAssertEqual(try store.leases().count, 1); XCTAssertEqual(Processes.info(token.pid)?.2, 4)
        lease.expires = Processes.now - 1; try store.leaseTransaction { _ in try store.saveLeases([lease]) }; recovery.tick()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(try store.leases().isEmpty); XCTAssertNotEqual(Processes.info(token.pid)?.2, 4)
    }
    func testAgentFreezeAndConfiguredTimeoutActuallyEndOnlyFixture() throws {
        let (task, token, hash) = try fixture(); defer { finish(task, token, hash) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }; let store = try Store(root: dir)
        let me = try XCTUnwrap(Processes.info(getpid())?.0)
        try store.heartbeat(Heartbeat(token: me, uptime: Processes.now), to: "recovery-heartbeat.json")
        var p = DetectionTests().policy(); p.identity.teamID = Signing.live(token.pid)?.team
        var settings = Settings(); settings.apps = [p]; try store.write(settings, to: "settings.json")
        let engine = try GuardEngine(store: store, queue: DispatchQueue(label: "test.engine"))
        let reading = ProcessReading(token: token, footprint: 32 * MiB, verified: true, stopped: false, signingHash: hash)
        let now = Processes.now
        try engine.freeze(reading, policy: p, now: now); Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(Processes.info(token.pid)?.2, 4)
        XCTAssertEqual(try store.leases().first?.deadline, now + 120)
        try engine.maintainLeases(now: now + 121); task.waitUntilExit()
        XCTAssertEqual(task.terminationReason, .uncaughtSignal); XCTAssertEqual(task.terminationStatus, SIGKILL)
        XCTAssertTrue(try store.leases().isEmpty)
        XCTAssertEqual(try store.events().last?.kind, "timeoutKilled")
    }
    func testEmergencySignalActuallyEndsFixtureWithoutCreatingLease() throws {
        let (task, token, hash) = try fixture(); defer { finish(task, token, hash) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }; let store = try Store(root: dir)
        var p = DetectionTests().policy(); p.identity.teamID = Signing.live(token.pid)?.team
        var settings = Settings(); settings.apps = [p]; try store.write(settings, to: "settings.json")
        let engine = try GuardEngine(store: store, queue: DispatchQueue(label: "test.engine"))
        let reading = ProcessReading(token: token, footprint: 32 * MiB, verified: true, stopped: false, signingHash: hash)
        try engine.terminate(reading, appID: p.id, kind: "emergencyKilled"); task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, SIGKILL); XCTAssertTrue(try store.leases().isEmpty)
    }
    func testResumeOffOnlyAllowsEndingAfterAgentRestartAndDoesNotWriteLeaseFiles() throws {
        let (task, token, hash) = try fixture(); defer { finish(task, token, hash) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }; let store = try Store(root: dir)
        let owner = try XCTUnwrap(Processes.info(getpid())?.0)
        var p = DetectionTests().policy(); p.identity.teamID = Signing.live(token.pid)?.team
        var settings = Settings(); settings.apps = [p]; try store.write(settings, to: "settings.json")
        let agent = try GuardEngine(store: store, queue: DispatchQueue(label: "test.resumePolicy"))
        let recovery = try RecoveryEngine(store: store)
        var deadOwner = owner; deadOwner.startMicroseconds += 1
        var lease = FreezeLease(appID: p.id, process: token, signingHash: hash, owner: deadOwner, now: Processes.now - 240, timeout: 120)
        lease.phase = .frozen; try store.leaseTransaction { _ in try store.saveLeases([lease]) }
        try SignalControl.send(SIGSTOP, to: token, hash: hash); Thread.sleep(forTimeInterval: 0.1)
        recovery.tick(); try agent.maintainLeases(now: Processes.now)
        XCTAssertEqual(Processes.info(token.pid)?.2, 4); XCTAssertNil(try store.leases().first?.deadline)
        for action in ["resume", "hold", "quit"] {
            XCTAssertEqual(agent.handle(WireRequest(action, value: lease.id)).error, "resumeDisabled")
        }
        settings.guardEnabled = false
        XCTAssertEqual(agent.handle(WireRequest("settings", data: try JSONEncoder().encode(settings))).error, "resumeDisabled")
        XCTAssertEqual(Processes.info(token.pid)?.2, 4)
        XCTAssertFalse(store.exists("leases.json"))
        XCTAssertNil(agent.handle(WireRequest("terminate", value: lease.id)).error)
        task.waitUntilExit(); XCTAssertEqual(task.terminationStatus, SIGKILL); XCTAssertTrue(try store.leases().isEmpty)
    }
}
