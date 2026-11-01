import Foundation
import MemoryGuardKit
import Darwin

// Dedicated, bounded test workload. Never allocates more than 64 MiB.
if CommandLine.arguments.contains("--fixture") {
    var blocks: [UnsafeMutableRawPointer] = []
    for _ in 0..<16 {
        let block = UnsafeMutableRawPointer.allocate(byteCount: 4 * 1024 * 1024, alignment: 4096)
        memset(block, 0x42, 4 * 1024 * 1024); blocks.append(block); usleep(100_000)
    }
    print("READY \(getpid())"); fflush(stdout)
    Thread.sleep(forTimeInterval: 120)
    blocks.forEach { $0.deallocate() }
} else {
    let system = Processes.system()
    print("Memory Guard \(BuildInfo.version) (\(BuildInfo.build))")
    print("System sample: \(system.valid); physical GiB: \(system.physical / GiB); used: \(system.percentage)%")
    if let current = Processes.info(getpid(), sample: true) { print("Own footprint MiB: \((current.3 ?? 0) / MiB)") }
    print("Readable same-user processes: \(Processes.all().count)")
    if let signature = Signing.live(getpid()) { print("Live signature verified: true; team present: \(signature.team != nil)") }
}
