import Foundation
import AppKit
import Security
import Darwin
import CGuard

public enum Processes {
    public static var now: Double { ProcessInfo.processInfo.systemUptime }
    public static func info(_ pid: Int32, sample: Bool = false) -> (ProcessToken, Int32, UInt32, Double?)? {
        var info = MGProcess()
        guard mg_process(pid, sample ? 1 : 0, &info) == 0 else { return nil }
        let path = withUnsafePointer(to: &info.path) { $0.withMemoryRebound(to: CChar.self, capacity: 4096) { String(cString: $0) } }
        let token = ProcessToken(pid: pid, uid: info.uid, startSeconds: info.start_seconds, startMicroseconds: info.start_microseconds, path: path)
        return (token, info.ppid, info.status, info.footprint_valid != 0 ? Double(info.footprint) : nil)
    }
    public static func all() -> [(ProcessToken, Int32)] {
        let capacity = max(4096, Int(mg_pids(nil, 0)) + 512)
        var pids = [Int32](repeating: 0, count: min(capacity, 65536))
        let count = mg_pids(&pids, Int32(pids.count))
        guard count > 0 else { return [] }
        return pids.prefix(min(Int(count), pids.count)).compactMap { pid in
            guard let (token, parent, _, _) = info(pid), token.uid == getuid() else { return nil }
            return (token, parent)
        }
    }
    public static func system() -> SystemReading {
        let raw = mg_system(); var result = SystemReading()
        result.valid = raw.valid != 0; result.physical = Double(raw.physical); result.used = Double(raw.used)
        result.swapUsed = Double(raw.swap_used); result.swapoutRate = Double(raw.swapouts)
        return result
    }
    public static func same(_ token: ProcessToken) -> Bool { info(token.pid)?.0 == token }
}

public enum Signing {
    private static let flags = SecCSFlags(rawValue: 0)
    public static func staticCode(_ url: URL) -> SecStaticCode? {
        var code: SecStaticCode?; guard SecStaticCodeCreateWithPath(url as CFURL, flags, &code) == errSecSuccess else { return nil }; return code
    }
    public static func information(_ code: SecStaticCode) -> [String: Any]? {
        var value: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &value) == errSecSuccess else { return nil }
        return value as? [String: Any]
    }
    public static func requirement(_ code: SecStaticCode) -> String? {
        var req: SecRequirement?; var text: CFString?
        guard SecCodeCopyDesignatedRequirement(code, flags, &req) == errSecSuccess, let req,
              SecRequirementCopyString(req, flags, &text) == errSecSuccess else { return nil }
        return text as String?
    }
    public static func requirement(at path: String) -> String? {
        guard let code = staticCode(URL(fileURLWithPath: path)) else { return nil }; return requirement(code)
    }
    public static func inspectApp(_ url: URL) throws -> AppIdentity {
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.pathExtension == "app", let bundle = Bundle(url: resolved), let id = bundle.bundleIdentifier,
              let executable = bundle.executableURL,
              !id.hasPrefix("local.memoryguard.") else { throw GuardError.failure("invalidApp") }
        let code = staticCode(resolved)
        let info = code.flatMap(information)
        let team = info?[kSecCodeInfoTeamIdentifier as String] as? String
        let signedID = info?[kSecCodeInfoIdentifier as String] as? String
        var anchor: SecRequirement?
        SecRequirementCreateWithString("anchor apple generic" as CFString, flags, &anchor)
        let trusted = code.map { SecStaticCodeCheckValidity($0, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), anchor) == errSecSuccess } ?? false
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw GuardError.failure("invalidApp") }
        return AppIdentity(name: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? resolved.deletingPathExtension().lastPathComponent,
                           bundleID: id, path: resolved.path, teamID: team,
                           requirement: code.flatMap(requirement), trusted: trusted && team != nil && signedID == id)
    }
    public static func live(_ pid: Int32) -> (code: SecCode, hash: String, team: String?)? {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary, flags, &code) == errSecSuccess,
              let code, SecCodeCheckValidity(code, flags, nil) == errSecSuccess else { return nil }
        var info: CFDictionary?
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, flags, &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any], let hash = values[kSecCodeInfoUnique as String] as? Data else { return nil }
        return (code, hash.map { String(format: "%02x", $0) }.joined(), values[kSecCodeInfoTeamIdentifier as String] as? String)
    }
    public static func matches(_ code: SecCode, requirement text: String) -> Bool {
        var req: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, flags, &req) == errSecSuccess else { return false }
        return SecCodeCheckValidity(code, flags, req) == errSecSuccess
    }
    public static func matchesApp(_ path: String, identity: AppIdentity) -> Bool {
        guard let reqText = identity.requirement, let code = staticCode(URL(fileURLWithPath: path)),
              let bundle = Bundle(path: path), bundle.bundleIdentifier == identity.bundleID else { return false }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(reqText as CFString, flags, &req) == errSecSuccess else { return false }
        return SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess
    }
}

public final class ProcessDiscovery {
    private var members: [String: [ProcessToken]] = [:]
    private var verified: [ProcessToken: (String, String)] = [:] // app ID / code hash
    private var bundleCache: [String: (String, Bool)] = [:]
    public private(set) var limitedApps = Set<String>()
    public init() {}
    public func reset() { members.removeAll(); verified.removeAll(); bundleCache.removeAll(); limitedApps.removeAll() }
    private func matchesBundle(_ path: String, _ identity: AppIdentity) -> Bool {
        guard let executable = Bundle(path: path)?.executableURL,
              let stat = try? FileManager.default.attributesOfItem(atPath: executable.path),
              let plist = try? FileManager.default.attributesOfItem(atPath: path + "/Contents/Info.plist") else { return false }
        let fingerprint = "\(stat[.systemFileNumber] ?? "")|\(stat[.size] ?? "")|\(stat[.modificationDate] ?? "")|\(plist[.modificationDate] ?? "")"
        let key = path + "|" + (identity.requirement ?? "")
        if let cached = bundleCache[key], cached.0 == fingerprint { return cached.1 }
        let valid = Signing.matchesApp(path, identity: identity); bundleCache[key] = (fingerprint, valid)
        return valid
    }
    public func refresh(_ policies: [AppPolicy]) {
        if bundleCache.count > 64 { bundleCache.removeAll(keepingCapacity: true) }
        limitedApps.removeAll(keepingCapacity: true)
        var trackedCount = 0
        let all = Processes.all()
        let parents = Dictionary(uniqueKeysWithValues: all.map { ($0.0.pid, $0.1) })
        let byPID = Dictionary(uniqueKeysWithValues: all.map { ($0.0.pid, $0.0) })
        let running = NSWorkspace.shared.runningApplications
        var next: [String: [ProcessToken]] = [:]; var nextVerified: [ProcessToken: (String, String)] = [:]
        for policy in policies where policy.enabled {
            var paths = [policy.identity.path]
            let roots = running.filter { $0.bundleIdentifier == policy.id }.filter {
                guard let path = $0.bundleURL?.path else { return false }
                if policy.identity.trusted { return matchesBundle(path, policy.identity) }
                return path == policy.identity.path
            }
            paths += roots.compactMap { $0.bundleURL?.path }
            paths = Array(Set(paths)).filter { !policy.identity.trusted || matchesBundle($0, policy.identity) }
            let rootPIDs = Set(roots.map(\.processIdentifier))
            for (token, _) in all {
                guard token.pid > 1, token.pid != getpid(), paths.contains(where: {
                    token.path.hasPrefix($0 + "/Contents/") && SafetyRules.within(token.path, bundle: $0)
                }) else { continue }
                var ancestor = token.pid; var seen = Set<Int32>(); var related = false
                while ancestor > 1 && seen.insert(ancestor).inserted {
                    if rootPIDs.contains(ancestor) { related = true; break }
                    guard let parent = parents[ancestor], let parentToken = byPID[parent], let childToken = byPID[ancestor],
                          parentToken.startSeconds < childToken.startSeconds ||
                            (parentToken.startSeconds == childToken.startSeconds && parentToken.startMicroseconds <= childToken.startMicroseconds) else { break }
                    ancestor = parent
                }
                // Retain known orphans, but never adopt a separately launched packaged CLI.
                guard related || members[policy.id]?.contains(token) == true else { continue }
                guard trackedCount < 512 else { limitedApps.insert(policy.id); continue }
                trackedCount += 1
                next[policy.id, default: []].append(token)
                if let cached = verified[token], cached.0 == policy.id { nextVerified[token] = cached }
                else if policy.identity.trusted, let signature = Signing.live(token.pid), signature.team == policy.identity.teamID,
                   Processes.same(token) { nextVerified[token] = (policy.id, signature.hash) }
            }
        }
        members = next; verified = nextVerified
    }
    public func sample(_ appID: String) -> (readings: [ProcessReading], failures: Int) {
        var failures = limitedApps.contains(appID) ? 1 : 0
        let readings: [ProcessReading] = (members[appID] ?? []).compactMap { token in
            guard let (current, _, status, bytes) = Processes.info(token.pid, sample: true), current == token else { return nil }
            guard let bytes else { failures += 1; return nil }
            return ProcessReading(token: token, footprint: bytes, verified: verified[token]?.0 == appID,
                                  stopped: status == 4, signingHash: verified[token]?.1)
        }
        return (readings, failures)
    }
}

public enum SignalControl {
    public static func validate(_ token: ProcessToken, hash: String) -> Bool {
        guard SafetyRules.maySignal(saved: token, current: Processes.info(token.pid)?.0, ownPID: getpid(), ownUID: getuid()),
              !["GuardAgent", "GuardRecovery", "MemoryGuard"].contains(URL(fileURLWithPath: token.path).lastPathComponent),
              let signature = Signing.live(token.pid), signature.hash == hash,
              Processes.same(token) else { return false }
        return true
    }
    public static func send(_ signal: Int32, to token: ProcessToken, hash: String) throws {
        guard [SIGSTOP, SIGCONT, SIGTERM, SIGKILL].contains(signal), validate(token, hash: hash) else { throw GuardError.failure("identityChanged") }
        guard kill(token.pid, signal) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
