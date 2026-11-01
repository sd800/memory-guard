import Foundation
import MemoryGuardKit

do {
    let store = try Store()
    let lock = try InstanceLock(store: store, name: "agent.lock")
    let queue = DispatchQueue(label: "local.memoryguard.engine", qos: .utility, autoreleaseFrequency: .workItem)
    let engine = try GuardEngine(store: store, queue: queue)
    let server = try IPCServer(store: store) { request, reply in queue.async { reply(engine.handle(request)) } }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
    timer.setEventHandler { autoreleasepool {
        if (Processes.info(getpid(), sample: true)?.3 ?? 0) > 128 * MiB {
            engine.recoverBeforeMemoryRestart(); exit(75)
        }
        engine.tick()
    } }; timer.resume()
    withExtendedLifetime((lock, engine, server, timer)) { RunLoop.main.run() }
} catch { fputs("GuardAgent: \(error.localizedDescription)\n", stderr); exit(1) }
