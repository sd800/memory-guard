import XCTest
@testable import MemoryGuardKit

final class DetectionTests: XCTestCase {
    func policy() -> AppPolicy {
        AppPolicy(identity: AppIdentity(name: "Fixture", bundleID: "test.fixture", path: "/Fixture.app", teamID: "TEST", requirement: "test", trusted: true), codexPreset: true)
    }
    func testCodexDefaultsAndGlobalDefaults() {
        let p = policy()
        XCTAssertEqual(p.mode, .protect); XCTAssertEqual(p.timeoutSeconds, 120); XCTAssertTrue(p.emergencyKill)
        XCTAssertFalse(Settings().showInMenuBar); XCTAssertTrue(Settings().showPercentage); XCTAssertFalse(Settings().startAtLogin)
        XCTAssertEqual(Settings().retentionDays, 3)
        XCTAssertEqual(Settings().language, .system)
        XCTAssertEqual(Settings().samplingSeconds, 2)
        XCTAssertTrue(Settings().apps.isEmpty)
    }
    func testAdaptiveThresholds() {
        let t = Thresholds(memory: 64 * GiB)
        XCTAssertEqual(t.warning, 16 * GiB); XCTAssertEqual(t.high, 24 * GiB)
        XCTAssertEqual(t.critical, 32 * GiB); XCTAssertEqual(t.emergency, 40 * GiB)
        XCTAssertEqual(Thresholds(memory: 16 * GiB).emergency, 10 * GiB)
        XCTAssertTrue(t.valid)
    }
    func testStableLargeProcessNeverKilledEvenWithCriticalPressure() {
        var d = Detector()
        for time in 0...180 {
            XCTAssertEqual(d.evaluate(bytes: 45 * GiB, time: Double(time), thresholds: Thresholds(memory: 64 * GiB), pressure: .critical,
                                      policy: policy(), recoveryReady: true, eligible: true, cooldown: false), .none)
        }
    }
    func testUnrelatedSystemPressureCannotFreezeStableSmallCodex() {
        var d = Detector()
        for time in 0...90 {
            XCTAssertEqual(d.evaluate(bytes: 5 * GiB, time: Double(time), thresholds: Thresholds(memory: 64 * GiB), pressure: .critical,
                                      policy: policy(), recoveryReady: true, eligible: true, cooldown: false), .none)
        }
    }
    func testEmergencySkipsPauseAndRecoveryDependency() {
        var d = Detector(); var decision: Decision = .none
        for time in 0...12 {
            decision = d.evaluate(bytes: (35 + Double(time) * 0.5) * GiB, time: Double(time), thresholds: Thresholds(memory: 64 * GiB), pressure: .normal,
                                  policy: policy(), recoveryReady: false, eligible: true, cooldown: false)
        }
        XCTAssertEqual(decision, .kill)
    }
    func testFreezeRequiresThreeConfirmationsAndRecovery() {
        for ready in [false, true] {
            var d = Detector(); var p = policy(); p.emergencyKill = false
            for time in 0...12 {
                let action = d.evaluate(bytes: (30 + Double(time) * 0.3) * GiB, time: Double(time), thresholds: Thresholds(memory: 64 * GiB), pressure: .normal,
                                        policy: p, recoveryReady: ready, eligible: true, cooldown: false)
                XCTAssertEqual(action, ready && time >= 12 ? .freeze : .none)
            }
        }
    }
    func testModesWhitelistIdentityAndCooldownBlockAllSignals() {
        for variant in 0...5 {
            var p = policy(); var eligible = true; var cooldown = false
            switch variant { case 0: p.mode = .monitor; case 1: p.mode = .alert; case 2: p.enabled = false
            case 3: p.identity.trusted = false; case 4: eligible = false; default: cooldown = true }
            var d = Detector()
            for time in 0...20 {
                XCTAssertEqual(d.evaluate(bytes: (35 + Double(time)) * GiB, time: Double(time), thresholds: Thresholds(memory: 64 * GiB), pressure: .critical,
                                          policy: p, recoveryReady: true, eligible: eligible, cooldown: cooldown), .none)
            }
        }
    }
    func testSlowLeakIsDetected() {
        var d = Detector(); var p = policy(); p.emergencyKill = false; var actions: [Decision] = []
        for time in 0...70 {
            actions.append(d.evaluate(bytes: (32 + Double(time) * 0.04) * GiB, time: Double(time), thresholds: Thresholds(memory: 64 * GiB), pressure: .normal,
                                      policy: p, recoveryReady: true, eligible: true, cooldown: false))
        }
        XCTAssertTrue(actions.contains(.freeze))
    }
    func testSamplingGapInvalidatesGrowthAndConsecutiveEvidence() {
        var h = History(); h.append(Sample(time: 0, bytes: 1)); h.append(Sample(time: 120, bytes: 900))
        XCTAssertNil(h.delta(seconds: 10)); XCTAssertEqual(h.samples.count, 1)
    }
    func testHistoryBoundedAcrossLongSimulatedRun() {
        var h = History()
        for time in 0...259200 { h.append(Sample(time: Double(time), bytes: Double(time))) }
        XCTAssertLessThanOrEqual(h.samples.count, 301); XCTAssertEqual(h.delta(seconds: 30), 30)
    }
    func testHysteresisRequiresSustainedDrop() {
        var d = Detector(); let t = Thresholds(memory: 64 * GiB)
        for time in 0...4 { _ = d.evaluate(bytes: 25 * GiB, time: Double(time), thresholds: t, pressure: .normal, policy: policy(), recoveryReady: true, eligible: false, cooldown: false) }
        XCTAssertEqual(d.level, .high)
        for time in 5...14 { _ = d.evaluate(bytes: 19 * GiB, time: Double(time), thresholds: t, pressure: .normal, policy: policy(), recoveryReady: true, eligible: false, cooldown: false) }
        XCTAssertEqual(d.level, .high)
        _ = d.evaluate(bytes: 19 * GiB, time: 15, thresholds: t, pressure: .normal, policy: policy(), recoveryReady: true, eligible: false, cooldown: false)
        XCTAssertEqual(d.level, .warning)
    }
}
