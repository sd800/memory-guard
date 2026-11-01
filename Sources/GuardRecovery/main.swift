import Foundation
import MemoryGuardKit

do {
    let store = try Store()
    let lock = try InstanceLock(store: store, name: "recovery.lock")
    let engine = try RecoveryEngine(store: store)
    let queue = DispatchQueue(label: "local.memoryguard.recovery", qos: .userInitiated, autoreleaseFrequency: .workItem)
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(100))
    timer.setEventHandler { autoreleasepool {
        if (Processes.info(getpid(), sample: true)?.3 ?? 0) > 64 * MiB {
            store.clearHeartbeat("recovery-heartbeat.json"); exit(75)
        }
        engine.tick()
    } }; timer.resume()
    withExtendedLifetime((lock, engine, timer)) { RunLoop.main.run() }
} catch { fputs("GuardRecovery: \(error.localizedDescription)\n", stderr); exit(1) }
