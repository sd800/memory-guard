import SwiftUI
import AppKit
import ServiceManagement
import MemoryGuardKit

enum Theme {
    static let artwork: NSImage = Bundle.main.url(forResource: "MemoryGuardArtwork", withExtension: "png").flatMap(NSImage.init(contentsOf:)) ?? NSImage()
    static let icon = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
        NSBezierPath(roundedRect: rect, xRadius: 56, yRadius: 56).addClip()
        NSGraphicsContext.current?.imageInterpolation = .high
        artwork.draw(in: rect); return true
    }
    static let purple = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ?
            NSColor(srgbRed: 0.68, green: 0.55, blue: 0.9, alpha: 1) : NSColor(srgbRed: 0.43, green: 0.28, blue: 0.67, alpha: 1)
    })
    static let ink = Color(red: 0.23, green: 0.15, blue: 0.37)
    static func color(_ level: Level) -> Color { level >= .critical ? .red : level >= .warning ? .orange : purple }
}
struct Card<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.06)))
    }
}
struct RootView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 10) {
                    Image("SidebarMark", bundle: .main).renderingMode(.original).interpolation(.high)
                        .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous)).accessibilityHidden(true)
                    Text("Memory Guard").font(.system(size: 15, weight: .semibold))
                }.padding(.top, 22).padding(.horizontal, 16)
                VStack(spacing: 6) {
                    ForEach(Page.allCases, id: \.self) { page in
                        Button { model.page = page } label: {
                            Label(page.title, systemImage: page.symbol).font(.system(size: 13, weight: model.page == page ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 13).padding(.vertical, 11)
                                .foregroundStyle(model.page == page ? Theme.purple : .primary)
                                .background(model.page == page ? Theme.purple.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 9))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 10)
                Spacer()
                HStack(spacing: 7) {
                    Circle().fill(model.online && model.snapshot.settings.guardEnabled ? Theme.purple : Color.secondary).frame(width: 6, height: 6)
                    Text(model.online ? (model.snapshot.settings.guardEnabled ? L("Guard active", "守护中") : L("Guard paused", "守护已暂停")) : L("Connecting", "连接中"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(20)
            }.navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 220)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Text(model.page.title).font(.system(size: 28, weight: .semibold, design: .rounded))
                        Spacer()
                        if model.page == .applications { Button { model.chooseApp() } label: { Image(systemName: "plus") }.help(L("Add application", "添加应用")) }
                        if model.page == .events { Button { model.exportDiagnostics() } label: { Image(systemName: "square.and.arrow.up") }.help(L("Export diagnostics", "导出诊断")) }
                    }
                    if !model.online { Label(Texts.message("offline"), systemImage: "antenna.radiowaves.left.and.right").foregroundStyle(.secondary) }
                    if let error = model.snapshot.error { Label(Texts.message(error), systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    switch model.page {
                    case .overview: OverviewView(model: model)
                    case .applications: ApplicationsView(model: model)
                    case .events: EventsView(model: model)
                    case .thresholds: ThresholdsView(model: model)
                    case .settings: SettingsView(model: model)
                    }
                }.padding(30).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(Theme.purple).frame(minWidth: 760, minHeight: 540)
        .disabled(model.isShuttingDown)
        .environment(\.locale, Locale(identifier: Texts.chinese ? "zh-Hans" : "en"))
        .alert(L("Memory Guard", "Memory Guard"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L("OK", "好")) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct OverviewView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Card {
            HStack(spacing: 28) {
                ZStack {
                    Circle().stroke(Theme.purple.opacity(0.1), lineWidth: 9)
                    Circle().trim(from: 0, to: CGFloat(model.snapshot.system.percentage) / 100).stroke(Theme.purple.gradient, style: StrokeStyle(lineWidth: 9, lineCap: .round)).rotationEffect(.degrees(-90))
                    VStack(spacing: 3) {
                        Text(model.snapshot.system.valid ? "\(model.snapshot.system.percentage)%" : "—").font(.system(size: 27, weight: .medium, design: .rounded)).monospacedDigit()
                        Text(L("Memory", "内存")).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(width: 112, height: 112).padding(5)
                VStack(alignment: .leading, spacing: 12) {
                    Text(memory(model.snapshot.system.used) + " / " + memory(model.snapshot.system.physical)).font(.system(size: 19, weight: .medium, design: .rounded)).monospacedDigit()
                    Label(pressureTitle, systemImage: "waveform.path").font(.callout).foregroundStyle(.secondary)
                    Text("Swap  " + memory(model.snapshot.system.swapUsed)).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                }
                Spacer(minLength: 0)
            }.help(L("System memory estimate from macOS VM counters.", "根据 macOS 虚拟内存计数估算的系统内存使用量。"))
        }
        ForEach(model.snapshot.leases) { lease in IncidentView(model: model, lease: lease) }
        if model.snapshot.settings.apps.isEmpty {
            Card { VStack(alignment: .leading, spacing: 14) {
                Text(L("Protect your workspace.", "守护你的工作空间。")).font(.title3.weight(.medium))
                Button(L("Add Codex", "添加 Codex")) { model.addCodex() }.buttonStyle(.borderedProminent)
            }.padding(.vertical, 12) }
        }
        ForEach(model.snapshot.settings.apps.filter(\.enabled)) { policy in
            let state = model.snapshot.apps.first { $0.id == policy.id }
            Card {
                HStack {
                    AppIcon(path: policy.identity.path)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(policy.displayName).font(.headline)
                        Text(Texts.mode(policy.mode)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(memory(state?.footprint ?? 0)).font(.system(size: 22, weight: .medium, design: .rounded)).monospacedDigit()
                            .help(L("Verified process footprints; shared memory may overlap.", "已验证进程的 Footprint 合计，共享内存可能重叠。"))
                        Text((state?.processes.isEmpty ?? true) ? L("Not running", "未运行") : Texts.level(state?.level ?? .normal))
                            .font(.caption).foregroundStyle(Theme.color(state?.level ?? .normal))
                    }
                }
                Sparkline(samples: state?.history ?? []).stroke(Theme.purple.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round)).frame(height: 58).padding(.top, 18)
                HStack { Text(L("Last 5 minutes", "最近 5 分钟")); Spacer(); Text(String(format: "%+.2f GiB / 30s", (state?.growth30 ?? 0) / GiB)) }
                    .font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit().padding(.top, 6)
                if policy.mode == .protect {
                    let t = policy.customThresholds ?? Thresholds(memory: Double(ProcessInfo.processInfo.physicalMemory))
                    HStack {
                        Text(policy.customThresholds == nil ? L("Recommended", "推荐值") : L("Custom", "自定义"))
                            .foregroundStyle(.secondary)
                        Text(L("Pause", "暂停") + "  " + memory(t.critical))
                        Text("Emergency  " + memory(t.emergency))
                        Spacer()
                        Button(L("Edit…", "编辑…")) { model.thresholdAppID = policy.id; model.page = .thresholds }
                    }.font(.caption).padding(.top, 14)
                }
                if let error = state?.error { Text(Texts.message(error)).font(.caption).foregroundStyle(.orange).padding(.top, 10) }
            }
        }
        if model.online && !model.snapshot.recoveryReady && model.snapshot.settings.apps.contains(where: { $0.mode == .protect }) {
            Label(Texts.message("recoveryUnavailable"), systemImage: "exclamationmark.shield").font(.caption).foregroundStyle(.orange)
        }
    }
    private var pressureTitle: String {
        switch model.snapshot.system.pressure {
        case .normal: return L("Pressure normal", "内存压力正常")
        case .warning: return L("Pressure elevated", "内存压力升高")
        case .critical: return L("Pressure critical", "内存压力严重")
        case .unknown: return L("Monitoring pressure signals", "压力信号监测中")
        }
    }
}
struct Sparkline: Shape {
    var samples: [Sample]
    func path(in rect: CGRect) -> Path {
        var path = Path(); guard samples.count > 1, let first = samples.first, let last = samples.last else { return path }
        let maximum = max(samples.map(\.bytes).max() ?? 1, 1)
        let minimum = min(samples.map(\.bytes).min() ?? 0, maximum * 0.8)
        for (index, sample) in samples.enumerated() {
            let x = rect.width * (sample.time - first.time) / max(last.time - first.time, 1)
            let y = rect.height * (1 - (sample.bytes - minimum) / max(maximum - minimum, 1))
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }; return path
    }
}
struct AppIcon: View {
    var path: String
    var body: some View { Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 38, height: 38) }
}
struct IncidentView: View {
    @ObservedObject var model: AppModel
    let lease: FreezeLease
    @State private var confirm = false
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(L("Process paused", "进程已暂停"), systemImage: "pause.circle.fill").font(.headline).foregroundStyle(.orange)
                    Spacer(); Text("PID \(lease.process.pid)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if let deadline = lease.deadline {
                    Text(L("Ends in \(max(0, Int(deadline - model.snapshot.uptime)))s without action", "未处理将在 \(max(0, Int(deadline - model.snapshot.uptime))) 秒后结束"))
                        .font(.callout).monospacedDigit()
                }
                HStack {
                    if model.snapshot.settings.allowResume {
                    Button(L("Keep paused", "保持暂停")) { model.send("hold", value: lease.id) }
                    Button(L("Resume", "恢复")) { model.send("resume", value: lease.id) }
                    Spacer()
                    Menu(L("End…", "结束…")) {
                        Button(L("Request exit", "尝试退出")) { model.send("quit", value: lease.id) }
                        Button(L("Force end…", "强制结束…"), role: .destructive) { confirm = true }
                    }.fixedSize()
                    } else {
                        Spacer()
                        Button(L("End process…", "结束进程…"), role: .destructive) { confirm = true }
                    }
                }.disabled(model.busy)
            }
        }.alert(L("End this process?", "结束此进程？"), isPresented: $confirm) {
            Button(L("Cancel", "取消"), role: .cancel) {}
            Button(L("Force end", "强制结束"), role: .destructive) { model.send("terminate", value: lease.id) }
        } message: { Text(L("The current task may be lost.", "可能丢失当前任务。")) }
    }
}

struct ApplicationsView: View {
    @ObservedObject var model: AppModel
    @State private var editing: AppPolicy?
    @State private var running = false
    var body: some View {
        VStack(spacing: 14) {
            ForEach(model.snapshot.settings.apps) { policy in
                Card {
                    HStack(spacing: 12) {
                        AppIcon(path: policy.identity.path)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(policy.displayName).font(.headline)
                            Text(policy.id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { policy.enabled }, set: { value in var copy = policy; copy.enabled = value; model.savePolicy(copy) })).toggleStyle(.switch).labelsHidden()
                        Button { editing = policy } label: { Image(systemName: "slider.horizontal.3") }.help(L("Protection settings", "保护设置"))
                    }
                }
            }
            HStack {
                Button { model.chooseApp() } label: { Label(L("Add application", "添加应用"), systemImage: "plus") }
                Button(L("Running applications…", "正在运行的应用…")) { running = true }
                Spacer()
            }.padding(.top, 8)
        }.disabled(model.busy || !model.online)
            .sheet(item: $editing) { policy in PolicyEditor(model: model, policy: policy) }
            .sheet(isPresented: $running) { RunningAppsView(model: model) }
    }
}
struct RunningAppsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    private var apps: [NSRunningApplication] { NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != BuildInfo.appID && $0.bundleURL != nil }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("Running applications", "正在运行的应用")).font(.title2.weight(.semibold))
            List(apps, id: \.processIdentifier) { app in
                HStack {
                    Image(nsImage: app.icon ?? NSImage()).resizable().frame(width: 28, height: 28)
                    VStack(alignment: .leading) { Text(app.localizedName ?? ""); Text(app.bundleIdentifier ?? "").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button(L("Add", "添加")) { model.send("add", value: app.bundleURL?.path); dismiss() }
                        .disabled(model.snapshot.settings.apps.contains { $0.id == app.bundleIdentifier })
                }.padding(.vertical, 4)
            }
            HStack { Spacer(); Button(L("Done", "完成")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 510, height: 440)
    }
}
struct PolicyEditor: View {
    @ObservedObject var model: AppModel
    @State var policy: AppPolicy
    @Environment(\.dismiss) var dismiss
    @State private var remove = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { AppIcon(path: policy.identity.path); Text(policy.displayName).font(.title2.weight(.semibold)); Spacer() }
            Form {
                Picker(L("Mode", "模式"), selection: $policy.mode) {
                    ForEach(Mode.allCases, id: \.self) { mode in Text(Texts.mode(mode)).tag(mode) }
                }.disabled(!policy.identity.trusted)
                if policy.mode == .protect {
                    Picker(L("No response", "未响应时"), selection: $policy.timeoutSeconds) {
                        Text(L("Keep paused", "保持暂停")).tag(0)
                        Text(L("End after 2 minutes", "2 分钟后结束")).tag(120)
                        Text(L("End after 5 minutes", "5 分钟后结束")).tag(300)
                    }
                    Toggle(L("End immediately at Emergency", "Emergency 时立即结束"), isOn: $policy.emergencyKill)
                    Text(L("Automatic ending may lose the current task, even when notifications are silenced.", "自动结束可能丢失当前任务，通知静音时仍会执行。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !policy.identity.trusted { Text(Texts.message("monitorOnlyIdentity")).foregroundStyle(.orange).font(.caption) }
            }.formStyle(.grouped)
            HStack {
                Button(L("Remove…", "移除…"), role: .destructive) { remove = true }
                Spacer()
                Button(L("Cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Save", "保存")) {
                    model.savePolicy(policy); dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 490).tint(Theme.purple)
            .alert(L("Remove protection?", "移除保护？"), isPresented: $remove) {
                Button(L("Cancel", "取消"), role: .cancel) {}
                Button(L("Remove", "移除"), role: .destructive) { model.remove(policy.id); dismiss() }
            } message: { Text(model.snapshot.settings.allowResume ? L("Paused processes will be resumed first.", "已暂停的进程将先恢复。") : L("End any paused processes first.", "请先结束已暂停的进程。")) }
    }

}
struct ThresholdsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let selected = model.snapshot.settings.apps.first(where: { $0.id == model.thresholdAppID }) ?? model.snapshot.settings.apps.first {
            if model.snapshot.settings.apps.count > 1 {
                Picker(L("Application", "应用"), selection: Binding(get: { selected.id }, set: { model.thresholdAppID = $0 })) {
                    ForEach(model.snapshot.settings.apps) { Text($0.displayName).tag($0.id) }
                }.frame(maxWidth: 340)
            }
            ThresholdCard(model: model, policy: selected).id(selected.id)
        } else {
            Card {
                Text(L("Recommended for this Mac", "这台 Mac 的推荐值")).font(.headline)
                let t = Thresholds(memory: Double(ProcessInfo.processInfo.physicalMemory))
                Text(L("Automatic pause", "自动暂停") + "  " + memory(t.critical) + "    ·    Emergency  " + memory(t.emergency)).padding(.vertical, 12)
                Button(L("Add application…", "添加应用…")) { model.chooseApp() }
            }
        }
    }
}
struct ThresholdCard: View {
    @ObservedObject var model: AppModel
    let policy: AppPolicy
    @State private var critical = ""
    @State private var emergency = ""
    private let recommended = Thresholds(memory: Double(ProcessInfo.processInfo.physicalMemory))
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    AppIcon(path: policy.identity.path); Text(policy.displayName).font(.headline); Spacer()
                    Text(memory(Double(ProcessInfo.processInfo.physicalMemory)) + " RAM").foregroundStyle(.secondary)
                }
                Divider()
                threshold(L("Automatic pause", "自动暂停"), value: $critical)
                threshold(L("Emergency force-end", "Emergency 强制结束"), value: $emergency)
                HStack {
                    Text(L("Recommended", "推荐值") + ": " + memory(recommended.critical) + " / " + memory(recommended.emergency)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Use recommended", "使用推荐值")) { load(recommended) }.controlSize(.small)
                }
                if thresholds == nil {
                    Text(L("Enter positive thresholds below physical memory. Emergency must be higher than pause.", "请输入小于本机内存的有效阈值；强制结束值必须高于暂停值。"))
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack { Spacer()
                    Button(L("Save", "保存")) {
                        guard let t = thresholds else { return }
                        var updated = policy; updated.customThresholds = t == recommended ? nil : t; model.savePolicy(updated)
                    }.buttonStyle(.borderedProminent).disabled(thresholds == nil || thresholds == (policy.customThresholds ?? recommended))
                }
            }
        }.onAppear { load(policy.customThresholds ?? recommended) }
        .onChange(of: policy.customThresholds) { value in load(value ?? recommended) }
    }
    private func load(_ t: Thresholds) {
        critical = String(format: "%.6g", t.critical / GiB); emergency = String(format: "%.6g", t.emergency / GiB)
    }
    private var thresholds: Thresholds? {
        guard let pause = Double(critical.replacingOccurrences(of: ",", with: ".")),
              let end = Double(emergency.replacingOccurrences(of: ",", with: ".")) else { return nil }
        if pause * GiB == recommended.critical && end * GiB == recommended.emergency { return recommended }
        var t = policy.customThresholds ?? recommended
        t.critical = pause * GiB; t.emergency = end * GiB
        if t.high >= t.critical { t.warning = t.critical * 0.5; t.high = t.critical * 0.75 }
        return t.valid && end * GiB < Double(ProcessInfo.processInfo.physicalMemory) ? t : nil
    }
    private func threshold(_ title: String, value: Binding<String>) -> some View {
        HStack { Text(title); Spacer(); TextField("", text: value).frame(width: 70).multilineTextAlignment(.trailing).accessibilityLabel(title); Text("GiB").foregroundStyle(.secondary) }
    }
}
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var clearDiagnostics = false
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                settingToggle(L("Protection", "保护"), isOn: Binding(get: { model.snapshot.settings.guardEnabled }, set: { value in model.update { $0.guardEnabled = value } }))
                settingToggle(L("Allow resuming paused processes", "允许恢复已暂停的进程"), isOn: Binding(get: { model.snapshot.settings.allowResume }, set: { value in model.update { $0.allowResume = value } }))
                Divider()
                settingToggle(L("Start at login", "登录时启动"), isOn: Binding(get: { model.snapshot.settings.startAtLogin }, set: model.setLogin))
                settingToggle(L("Show in menu bar", "在菜单栏显示"), isOn: Binding(get: { model.snapshot.settings.showInMenuBar }, set: { value in model.update { $0.showInMenuBar = value } }))
                settingToggle(L("Memory percentage in menu bar", "菜单栏显示内存百分比"), isOn: Binding(get: { model.snapshot.settings.showPercentage }, set: { value in model.update { $0.showPercentage = value } }))
                    .disabled(!model.snapshot.settings.showInMenuBar)
                Divider()
                HStack {
                    Text(L("Sampling interval", "采样间隔")); Spacer()
                    Picker("", selection: Binding(get: { model.snapshot.settings.samplingSeconds }, set: { value in model.update { $0.samplingSeconds = value } })) {
                        Text(L("1 second", "1 秒")).tag(1); Text(L("2 seconds", "2 秒")).tag(2); Text(L("5 seconds", "5 秒")).tag(5)
                    }.labelsHidden().frame(width: 116).accessibilityLabel(L("Sampling interval", "采样间隔"))
                }.frame(minHeight: 28).help(L("High-risk sampling automatically increases to once per second.", "高风险状态下自动提升为每秒采样。"))
                HStack {
                    Text(L("Language", "语言")); Spacer()
                    Picker("", selection: Binding(get: { model.snapshot.settings.language }, set: { value in model.update { $0.language = value } })) {
                        Text(L("System", "跟随系统")).tag(AppLanguage.system)
                        Text("简体中文").tag(AppLanguage.chinese)
                        Text("English").tag(AppLanguage.english)
                    }.labelsHidden().frame(width: 116).accessibilityLabel(L("Language", "语言"))
                }.frame(minHeight: 28)
                HStack {
                    Text(L("Event retention", "事件保留")); Spacer()
                    Picker("", selection: Binding(get: { model.snapshot.settings.retentionDays }, set: { value in model.update { $0.retentionDays = value } })) {
                        Text(L("3 days", "3 天")).tag(3); Text(L("5 days", "5 天")).tag(5); Text(L("7 days", "7 天")).tag(7)
                        Text(L("30 days", "30 天")).tag(30); Text(L("90 days", "90 天")).tag(90)
                    }.labelsHidden().frame(width: 116).accessibilityLabel(L("Event retention", "事件保留"))
                }.frame(minHeight: 28)
                HStack {
                    Button(L("Notifications…", "通知…")) { if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) } }
                    Spacer()
                    Button(L("Clear diagnostics…", "清除诊断…")) { clearDiagnostics = true }
                        .alert(L("Clear diagnostic history?", "清除诊断事件记录？"), isPresented: $clearDiagnostics) {
                            Button(L("Cancel", "取消"), role: .cancel) {}
                            Button(L("Clear", "清除"), role: .destructive) { model.send("clearDiagnostics") }
                        }
                    Button(L("Export diagnostics…", "导出诊断…")) { model.exportDiagnostics() }
                }
                Divider()
                HStack {
                    Spacer()
                    Button(L("Quit Completely", "完全退出")) { (NSApp.delegate as? AppDelegate)?.quitCompletely() }
                        .help(L("Stop background protection and quit Memory Guard.", "停止后台保护并退出 Memory Guard。"))
                }
            }.toggleStyle(.switch).transaction { $0.animation = nil }
        }
        if model.loginNeedsApproval {
            Button(L("Review background access…", "检查后台运行权限…")) { SMAppService.openSystemSettingsLoginItems() }
        }
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Memory Guard")
                Text("© 2026 Songming.org")
            }
            Spacer()
            Text("\(BuildInfo.version) (\(BuildInfo.build))").monospacedDigit()
        }.font(.caption).foregroundStyle(.tertiary)
    }
    private func settingToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title); Spacer(minLength: 20)
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).accessibilityLabel(title)
        }.frame(minHeight: 28)
    }
}
struct EventsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if model.snapshot.events.isEmpty {
            Card { Label(L("All quiet.", "一切平静。"), systemImage: "checkmark.shield").foregroundStyle(.secondary).padding(.vertical, 28) }
        } else {
            Card {
                LazyVStack(spacing: 0) {
                    ForEach(model.snapshot.events) { event in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: event.kind.contains("Killed") ? "xmark.circle" : event.kind == "frozen" ? "pause.circle" : "circle.dotted").foregroundStyle(Theme.purple).frame(width: 18)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(Texts.message(event.kind)).font(.callout)
                                Text(model.snapshot.settings.apps.first(where: { $0.id == event.appID })?.displayName ?? event.appID).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(event.date, format: .dateTime.month().day().hour().minute().second()).font(.caption).foregroundStyle(.tertiary)
                        }.padding(.vertical, 14)
                        if event.id != model.snapshot.events.last?.id { Divider().opacity(0.5) }
                    }
                }
            }
        }
    }
}
