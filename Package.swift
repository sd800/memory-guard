// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MemoryGuard", platforms: [.macOS(.v13)],
    products: [
        .library(name: "MemoryGuardKit", targets: ["MemoryGuardKit"]),
        .executable(name: "MemoryGuard", targets: ["MemoryGuard"]),
        .executable(name: "GuardAgent", targets: ["GuardAgent"]),
        .executable(name: "GuardRecovery", targets: ["GuardRecovery"]),
        .executable(name: "GuardProbe", targets: ["GuardProbe"])
    ],
    targets: [
        .target(name: "CGuard", linkerSettings: [.linkedLibrary("proc")]),
        .target(name: "MemoryGuardKit", dependencies: ["CGuard"]),
        .executableTarget(name: "MemoryGuard", dependencies: ["MemoryGuardKit"]),
        .executableTarget(name: "GuardAgent", dependencies: ["MemoryGuardKit"]),
        .executableTarget(name: "GuardRecovery", dependencies: ["MemoryGuardKit"]),
        .executableTarget(name: "GuardProbe", dependencies: ["MemoryGuardKit"]),
        .testTarget(name: "MemoryGuardTests", dependencies: ["MemoryGuardKit"])
    ]
)
