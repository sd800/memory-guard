import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications
import MemoryGuardKit

enum Page: String, CaseIterable {
    case overview, applications, thresholds, events, settings
    var title: String {
        switch self { case .overview: return L("Overview", "概览"); case .applications: return L("Applications", "应用")
        case .thresholds: return L("Thresholds", "阈值"); case .events: return L("Events", "事件"); case .settings: return L("Settings", "设置") }
    }
    var symbol: String {
        switch self { case .overview: return "shield.lefthalf.filled"; case .applications: return "square.stack.3d.up"
        case .thresholds: return "gauge.with.dots.needle.50percent"; case .events: return "clock.arrow.circlepath"; case .settings: return "slider.horizontal.3" }
    }
}

final class AppModel: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var snapshot = Snapshot()
    @Published var online = false
    @Published var busy = false
    @Published var page: Page = .overview
    @Published var thresholdAppID: String?
    @Published var error: String?
    @Published var loginNeedsApproval = false
    @Published private(set) var isShuttingDown = false
    let store: Store
    private let client: IPCClient
    private var timer: Timer?
    private var pollStarted: Date?
    private var lastNotifications = Set<String>()
    private var initialSetupDone = false
    private var pendingSettings: MemoryGuardKit.Settings?
    private var confirmedSettings = MemoryGuardKit.Settings()
    private var settingsRevision = 0
    private var settingsInFlight = false
    private var loginInFlight = false
    private var desiredLogin: Bool?
    var hasPendingWrites: Bool { pendingSettings != nil || settingsInFlight || loginInFlight }
    var onUpdate: (() -> Void)?
    init(store: Store) {
        self.store = store; client = IPCClient(store: store)
        super.init()
        if let settings = try? store.read("settings.json", as: MemoryGuardKit.Settings.self) {
            snapshot.settings = settings; confirmedSettings = settings; Texts.language = settings.language
        }
        lastNotifications = Set((try? store.read("notifications.json", as: [String].self)) ?? [])
    }
    deinit { timer?.invalidate(); client.disconnect() }
    func start() {
        do { try IPC.ensureServices(store: store) }
        catch { self.error = L("Could not register background services.", "无法注册后台服务。") }
        configureNotifications()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func refresh() {
        guard !isShuttingDown else { return }
        if let started = pollStarted, Date().timeIntervalSince(started) < 5 { return }
        pollStarted = Date()
        let revision = settingsRevision
        client.request(WireRequest("snapshot")) { [weak self] reply in
            guard let self, !self.isShuttingDown else { return }; self.pollStarted = nil
            if let snapshot = reply.snapshot {
                self.accept(snapshot, preserveSettings: revision != self.settingsRevision); self.online = true
                self.deliverEvents(); self.firstRun()
                self.flushSettings()
            } else { self.online = false }
            self.loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
            self.onUpdate?()
        }
    }
    func stopForQuit(completion: @escaping (Bool) -> Void) {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        client.disconnect()
        let store = self.store
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do { try IPC.stopServices(store: store) }
            catch {
                failure = (error as? GuardError)?.errorDescription ?? "shutdownFailed"
                // A partial bootout must not leave the app claiming that protection is running.
                if failure == "shutdownFailed" {
                    do { try IPC.ensureServices(store: store) }
                    catch { failure = "serviceRegistrationFailed" }
                }
            }
            let result = failure
            DispatchQueue.main.async {
                self.isShuttingDown = false
                if let result {
                    if result == "quitWithPausedProcesses" { self.page = .overview }
                    self.error = Texts.message(result)
                    self.refresh()
                }
                completion(result == nil)
            }
        }
    }
    func send(_ action: String, value: String? = nil, data: Data? = nil, completion: (() -> Void)? = nil) {
        busy = true
        client.request(WireRequest(action, data: data, value: value)) { [weak self] reply in
            guard let self else { return }; self.busy = false
            if let error = reply.error { self.error = Texts.message(error) }
            else if let snapshot = reply.snapshot { self.accept(snapshot); completion?() }
            self.refresh(); self.onUpdate?()
        }
    }
    func update(_ change: (inout MemoryGuardKit.Settings) -> Void) {
        var settings = pendingSettings ?? snapshot.settings; change(&settings)
        settingsRevision += 1; pendingSettings = settings
        // Show the user's intent immediately. Poll replies cannot roll an in-flight switch back.
        applyLanguage(settings.language); snapshot.settings = settings; onUpdate?()
        flushSettings()
    }
    private func accept(_ incoming: Snapshot, preserveSettings: Bool = false) {
        var value = incoming
        if !preserveSettings { confirmedSettings = incoming.settings }
        if let pendingSettings { value.settings = pendingSettings }
        else if preserveSettings { value.settings = snapshot.settings }
        applyLanguage(value.settings.language)
        snapshot = value
    }
    private func flushSettings() {
        guard !settingsInFlight, online, let desired = pendingSettings, let data = try? JSONEncoder().encode(desired) else { return }
        settingsInFlight = true; let revision = settingsRevision
        client.request(WireRequest("settings", data: data)) { [weak self] reply in
            guard let self else { return }; self.settingsInFlight = false
            if let error = reply.error {
                if error == "offline" { self.online = false; return }
                if revision == self.settingsRevision {
                    self.pendingSettings = nil; self.applyLanguage(self.confirmedSettings.language)
                    self.snapshot.settings = self.confirmedSettings
                }
                self.error = Texts.message(error)
            } else if let result = reply.snapshot {
                if revision == self.settingsRevision { self.pendingSettings = nil }
                self.accept(result)
            }
            self.onUpdate?(); self.flushSettings()
        }
    }
    func savePolicy(_ policy: AppPolicy) {
        update { settings in if let index = settings.apps.firstIndex(where: { $0.id == policy.id }) { settings.apps[index] = policy } }
    }
    func remove(_ id: String) { update { $0.apps.removeAll { $0.id == id } } }
    func toggleProtection() { update { $0.guardEnabled.toggle() } }
    func chooseApp() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false; panel.title = L("Add application", "添加应用")
        if panel.runModal() == .OK, let url = panel.url { send("add", value: url.path) }
    }
    func addCodex() {
        let url = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.openai.codex" }?.bundleURL ??
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
        if let url { send("add", value: url.path) }
        else { chooseApp() }
    }
    private func firstRun() {
        guard !initialSetupDone else { return }; initialSetupDone = true
        if !store.exists("onboarding.json") {
            if snapshot.settings.apps.isEmpty,
               let url = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.openai.codex" })?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
                send("add", value: url.path)
            }
            try? store.write(true, to: "onboarding.json")
        }
    }
    func setLogin(_ enabled: Bool) {
        update { $0.startAtLogin = enabled }
        desiredLogin = enabled; flushLogin()
    }
    private func flushLogin() {
        guard !loginInFlight, let enabled = desiredLogin else { return }; loginInFlight = true
        Task.detached { [weak self] in
            guard let model = self else { return }
            var failed = false
            do {
                let service = SMAppService.mainApp
                if enabled {
                    if service.status == .notRegistered || service.status == .notFound { try service.register() }
                } else if service.status != .notRegistered { try await service.unregister() }
            } catch { failed = true }
            let didFail = failed
            await MainActor.run {
                model.loginInFlight = false
                if model.desiredLogin == enabled {
                    model.desiredLogin = nil
                    if didFail {
                        model.update { $0.startAtLogin = SMAppService.mainApp.status == .enabled }
                        model.error = L("Login setup needs attention in System Settings.", "请在系统设置中检查登录项。")
                        model.loginNeedsApproval = true
                    }
                }
                model.flushLogin(); model.onUpdate?()
            }
        }
    }
    func exportDiagnostics() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "MemoryGuard-Diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Deliberately exclude executable paths, signing requirements, command lines and environment.
        let report: [String: Any] = ["version": BuildInfo.version, "build": BuildInfo.build,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "systemMemoryBytes": snapshot.system.physical, "memoryUsedBytes": snapshot.system.used,
            "pressure": snapshot.system.pressure.rawValue, "recoveryReady": snapshot.recoveryReady,
            "apps": snapshot.settings.apps.map { ["bundleID": $0.id, "mode": $0.mode.rawValue, "emergencyKill": $0.emergencyKill, "timeoutSeconds": $0.timeoutSeconds] as [String: Any] },
            "events": snapshot.events.map { ["time": ISO8601DateFormatter().string(from: $0.date), "appID": $0.appID, "kind": $0.kind, "pid": $0.pid ?? 0] as [String: Any] }]
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic) }
        catch { self.error = error.localizedDescription }
    }
    private func applyLanguage(_ language: AppLanguage) {
        if Texts.language != language { Texts.language = language; configureNotifications(requestPermission: false) }
    }
    private func configureNotifications(requestPermission: Bool = true) {
        let center = UNUserNotificationCenter.current(); center.delegate = self
        let resume = UNNotificationAction(identifier: "resume", title: L("Resume", "恢复"))
        let hold = UNNotificationAction(identifier: "hold", title: L("Keep paused", "保持暂停"))
        let category = UNNotificationCategory(identifier: "incident", actions: [hold, resume], intentIdentifiers: [])
        center.setNotificationCategories([category])
        if requestPermission { center.requestAuthorization(options: [.alert, .sound]) { _, _ in } }
    }
    private func deliverEvents() {
        let wanted: Set<String> = ["warning", "critical", "frozen", "emergencyKilled", "timeoutKilled", "signalFailed", "recovered", "recoveryFailed"]
        var changed = false
        for event in snapshot.events.reversed() where wanted.contains(event.kind) && !lastNotifications.contains(event.id) {
            lastNotifications.insert(event.id)
            changed = true
            guard Date().timeIntervalSince(event.date) < 180 else { continue }
            let content = UNMutableNotificationContent()
            content.title = Texts.message(event.kind)
            let name = snapshot.settings.apps.first { $0.id == event.appID }?.displayName ?? "Memory Guard"
            content.body = name
            content.sound = .default
            if let lease = snapshot.leases.first(where: { $0.process.pid == event.pid && $0.appID == event.appID }) {
                if snapshot.settings.allowResume { content.categoryIdentifier = "incident" }; content.userInfo = ["lease": lease.id]
                if let deadline = lease.deadline {
                    let seconds = max(0, Int(deadline - snapshot.uptime))
                    content.body += L(" · Ends in \(seconds)s without action", " · 未处理将在 \(seconds) 秒后结束")
                }
            }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: event.id, content: content, trigger: nil))
        }
        if lastNotifications.count > 1600 { lastNotifications = Set(snapshot.events.map(\.id)) }
        if changed { try? store.write(Array(lastNotifications), to: "notifications.json") }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            if let lease = response.notification.request.content.userInfo["lease"] as? String,
               ["resume", "hold"].contains(response.actionIdentifier) { if self.snapshot.settings.allowResume { self.send(response.actionIdentifier, value: lease) } }
            else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                self.page = .overview; (NSApp.delegate as? AppDelegate)?.showWindow()
            }
            completionHandler()
        }
    }
}
