import Foundation
import Darwin

@objc public protocol GuardProtocol {
    func request(_ data: Data, reply: @escaping (Data) -> Void)
}
public enum IPC {
    public static let serviceName = "local.memoryguard.agent"
    /// Register jobs for this login session only. SMAppService.mainApp controls future logins.
    public static func ensureServices(store: Store) throws {
        for (label, executable) in [("local.memoryguard.recovery", "GuardRecovery"), (serviceName, "GuardAgent")] {
            if launchctl(["print", "gui/\(getuid())/\(label)"]) == 0 { continue }
            var plist: [String: Any] = ["Label": label, "Program": helperPath(executable), "RunAtLoad": true,
                "KeepAlive": true, "ThrottleInterval": 10, "ProcessType": "Background", "LimitLoadToSessionType": "Aqua"]
            if executable == "GuardAgent" { plist["MachServices"] = [serviceName: true] }
            let name = label + ".session.plist"
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            if (try? Data(contentsOf: store.url(name))) != data { try store.writeData(data, to: name) }
            guard launchctl(["bootstrap", "gui/\(getuid())", store.url(name).path]) == 0 ||
                    launchctl(["print", "gui/\(getuid())/\(label)"]) == 0 else { throw GuardError.failure("serviceRegistrationFailed") }
        }
    }
    public static func stopServices(store: Store) throws {
        try stopServices(store: store, run: launchctl)
    }
    static func stopServices(store: Store, run: ([String]) -> Int32) throws {
        // freeze() holds the same lock from preparing its record through sending SIGSTOP.
        // Keeping it across bootout prevents a new pause between the check and shutdown.
        try store.leaseTransaction { leases in
            guard leases.isEmpty else { throw GuardError.failure("quitWithPausedProcesses") }
            for label in [serviceName, "local.memoryguard.recovery"] {
                let job = "gui/\(getuid())/\(label)"
                let status = run(["bootout", job])
                if status != 0 && run(["print", job]) != 113 { // launchctl: service not found
                    throw GuardError.failure("shutdownFailed")
                }
            }
        }
    }
    @discardableResult private static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/launchctl"); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus } catch { return -1 }
    }
    public static func helperPath(_ name: String) -> String {
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        if exe.path.contains(".app/Contents/MacOS/") {
            return exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers/\(name)").path
        }
        return exe.deletingLastPathComponent().appendingPathComponent(name).path
    }
    public static func appExecutable() -> String {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardized
        if exe.path.contains(".app/Contents/Helpers/") {
            return exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("MacOS/MemoryGuard").path
        }
        return exe.deletingLastPathComponent().appendingPathComponent("MemoryGuard").path
    }
    @discardableResult public static func launch(_ path: String) throws -> Process {
        let task = Process(); task.executableURL = URL(fileURLWithPath: path)
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try task.run(); return task
    }
    public static func heartbeatHealthy(_ name: String, store: Store) -> Bool {
        guard let beat = try? store.readHeartbeat(name) else { return false }
        let age = Processes.now - beat.uptime
        return age >= 0 && age < 6 && Processes.same(beat.token)
    }
}
public final class IPCServer: NSObject, NSXPCListenerDelegate, GuardProtocol {
    private let listener = NSXPCListener(machServiceName: IPC.serviceName)
    private let allowedRequirement: String
    private let handler: (WireRequest, @escaping (WireReply) -> Void) -> Void
    private var connections = [NSXPCConnection]()
    public init(store: Store, handler: @escaping (WireRequest, @escaping (WireReply) -> Void) -> Void) throws {
        guard let requirement = Signing.requirement(at: IPC.appExecutable()) else { throw GuardError.failure("unsignedClient") }
        self.allowedRequirement = requirement; self.handler = handler
        super.init(); listener.delegate = self; listener.resume()
    }
    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        connection.setCodeSigningRequirement(allowedRequirement)
        connection.exportedInterface = NSXPCInterface(with: GuardProtocol.self); connection.exportedObject = self
        connection.invalidationHandler = { [weak self, weak connection] in
            DispatchQueue.main.async { self?.connections.removeAll { $0 === connection } }
        }
        DispatchQueue.main.async { self.connections.append(connection) }
        connection.resume(); return true
    }
    public func request(_ data: Data, reply: @escaping (Data) -> Void) {
        guard data.count <= 512 * 1024, let request = try? JSONDecoder().decode(WireRequest.self, from: data) else {
            reply((try? JSONEncoder().encode(WireReply(error: "invalidRequest"))) ?? Data()); return
        }
        handler(request) { result in reply((try? JSONEncoder().encode(result)) ?? Data()) }
    }
}
public final class IPCClient {
    private var connection: NSXPCConnection?
    private let store: Store
    public init(store: Store) { self.store = store }
    public func disconnect() { connection?.invalidate(); connection = nil }
    public func request(_ request: WireRequest, completion: @escaping (WireReply) -> Void) {
        do {
            if connection == nil {
                guard let requirement = Signing.requirement(at: IPC.helperPath("GuardAgent")) else { throw GuardError.failure("offline") }
                let connection = NSXPCConnection(machServiceName: IPC.serviceName)
                connection.remoteObjectInterface = NSXPCInterface(with: GuardProtocol.self)
                connection.setCodeSigningRequirement(requirement)
                connection.invalidationHandler = { [weak self] in DispatchQueue.main.async { self?.connection = nil } }
                connection.interruptionHandler = { [weak self] in DispatchQueue.main.async { self?.disconnect() } }
                connection.resume(); self.connection = connection
            }
            let proxy = connection?.remoteObjectProxyWithErrorHandler { [weak self] _ in
                DispatchQueue.main.async { self?.disconnect(); completion(WireReply(error: "offline")) }
            } as? GuardProtocol
            guard let proxy else { throw GuardError.failure("offline") }
            proxy.request(try JSONEncoder().encode(request)) { data in
                let reply = (try? JSONDecoder().decode(WireReply.self, from: data)) ?? WireReply(error: "invalidReply")
                DispatchQueue.main.async { completion(reply) }
            }
        } catch { completion(WireReply(error: "offline")) }
    }
}
