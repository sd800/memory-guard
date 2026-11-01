import AppKit
import SwiftUI
import MemoryGuardKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: AppModel!
    private var window: NSWindow?
    private var statusItem: NSStatusItem!
    private var appLock: InstanceLock?
    private var menuLanguage: AppLanguage = .system
    private var closeWhenSaved = false
    private var quitAllWhenSaved = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let store = try Store(); appLock = try InstanceLock(store: store, name: "interface.lock")
            NSApp.applicationIconImage = Theme.icon
            model = AppModel(store: store)
            installMenus()
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            model.onUpdate = { [weak self] in
                self?.updateStatus()
                guard let self, !self.model.isShuttingDown else { return }
                if self.quitAllWhenSaved && !self.model.online && self.model.hasPendingWrites {
                    self.quitAllWhenSaved = false
                    self.model.error = L("Reconnect to save the pending changes, then quit again.", "请在连接恢复、设置保存后再次退出。")
                    self.showWindow()
                } else if self.quitAllWhenSaved && !self.model.hasPendingWrites && !self.model.busy { self.quitCompletely() }
                else if self.closeWhenSaved && !self.model.hasPendingWrites { NSApp.terminate(nil) }
            }
            model.start(); updateStatus()
            let event = NSAppleEventManager.shared().currentAppleEvent
            let loginLaunch = event?.eventID == kAEOpenApplication && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
            if !CommandLine.arguments.contains("--background") && !loginLaunch { showWindow() }
        } catch {
            let alert = NSAlert(); alert.messageText = "Memory Guard"; alert.informativeText = error.localizedDescription; alert.runModal()
            NSApp.terminate(nil)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    @objc func showWindow() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 910, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Memory Guard"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            window.contentView = NSHostingView(rootView: RootView(model: model)); window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 760, height: 540); window.delegate = self
            window.setFrameAutosaveName("MemoryGuard.Main"); window.center(); self.window = window
        }
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async { self.window = nil }
        if !model.snapshot.settings.showInMenuBar { quitInterface() }
    }
    @objc func settings() { model.page = .settings; showWindow() }
    @objc func overview() { model.page = .overview; showWindow() }
    @objc func thresholds() { model.page = .thresholds; showWindow() }
    @objc func applications() { model.page = .applications; showWindow() }
    @objc func events() { model.page = .events; showWindow() }
    @objc func toggleProtection() { model.toggleProtection() }
    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Memory Guard", .applicationVersion: BuildInfo.version, .version: BuildInfo.build, .applicationIcon: Theme.icon, .credits: NSAttributedString(string: ""), .init(rawValue: "Copyright"): "© 2026 Songming.org"])
    }
    @objc func exportReport() { showWindow(); model.exportDiagnostics() }
    @objc func quitInterface() {
        guard !model.isShuttingDown, !quitAllWhenSaved else { return }
        if model.hasPendingWrites && model.online { closeWhenSaved = true }
        else { NSApp.terminate(nil) }
    }
    @objc func quitCompletely() {
        guard !model.isShuttingDown else { return }
        closeWhenSaved = false
        if model.hasPendingWrites || model.busy {
            quitAllWhenSaved = true
            return
        }
        quitAllWhenSaved = false
        model.stopForQuit { stopped in
            if stopped { NSApp.terminate(nil) }
            else { self.showWindow() }
        }
    }
    private func item(_ title: String, _ symbol: String, _ action: Selector?, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(systemSymbolName: "circle", accessibilityDescription: title)
        item.target = target ?? self; return item
    }
    private func installMenus() {
        let main = NSMenu()
        let root = NSMenuItem(); let app = NSMenu(title: "Memory Guard"); root.submenu = app; main.addItem(root)
        app.addItem(item(L("About Memory Guard", "关于 Memory Guard"), "info.circle", #selector(about)))
        app.addItem(.separator())
        app.addItem(item(L("Settings…", "设置…"), "gearshape", #selector(settings), key: ","))
        app.addItem(item(L("Pause / resume protection", "暂停／恢复保护"), "pause.shield", #selector(toggleProtection)))
        app.addItem(.separator())
        let services = item(L("Services", "服务"), "gearshape.2", nil); services.submenu = NSMenu(title: services.title); app.addItem(services); NSApp.servicesMenu = services.submenu
        app.addItem(item(L("Hide Memory Guard", "隐藏 Memory Guard"), "eye.slash", #selector(NSApplication.hide(_:)), key: "h", target: NSApp))
        let others = item(L("Hide Others", "隐藏其他"), "rectangle.on.rectangle.slash", #selector(NSApplication.hideOtherApplications(_:)), key: "h", target: NSApp)
        others.keyEquivalentModifierMask = [.command, .option]; app.addItem(others)
        app.addItem(item(L("Show All", "全部显示"), "rectangle.on.rectangle", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp))
        app.addItem(.separator()); app.addItem(item(L("Quit Interface", "退出界面"), "power", #selector(quitInterface), key: "q"))
        app.addItem(item(L("Quit Completely", "退出运行"), "power.circle", #selector(quitCompletely)))
        let edit = NSMenu(title: L("Edit", "编辑")); let editRoot = NSMenuItem(); editRoot.submenu = edit; main.addItem(editRoot)
        for (title, zh, symbol, selector, key) in [("Undo", "撤销", "arrow.uturn.backward", "undo:", "z"), ("Redo", "重做", "arrow.uturn.forward", "redo:", "Z"), ("Cut", "剪切", "scissors", "cut:", "x"), ("Copy", "拷贝", "doc.on.doc", "copy:", "c"), ("Paste", "粘贴", "doc.on.clipboard", "paste:", "v"), ("Select All", "全选", "selection.pin.in.out", "selectAll:", "a")] {
            let menuItem = item(L(title, zh), symbol, NSSelectorFromString(selector), key: key); menuItem.target = nil; edit.addItem(menuItem)
        }
        let view = NSMenu(title: L("View", "显示")); let viewRoot = NSMenuItem(); viewRoot.submenu = view; main.addItem(viewRoot)
        view.addItem(item(Page.overview.title, Page.overview.symbol, #selector(overview), key: "1"))
        view.addItem(item(Page.applications.title, Page.applications.symbol, #selector(applications), key: "2"))
        view.addItem(item(Page.events.title, Page.events.symbol, #selector(events), key: "3"))
        view.addItem(item(Page.thresholds.title, Page.thresholds.symbol, #selector(thresholds), key: "4"))
        let windows = NSMenu(title: L("Window", "窗口")); let windowsRoot = NSMenuItem(); windowsRoot.submenu = windows; main.addItem(windowsRoot); NSApp.windowsMenu = windows
        let close = item(L("Close", "关闭"), "xmark.rectangle", #selector(NSWindow.performClose(_:)), key: "w"); close.target = nil; windows.addItem(close)
        let minimize = item(L("Minimize", "最小化"), "minus.rectangle", #selector(NSWindow.performMiniaturize(_:)), key: "m"); minimize.target = nil; windows.addItem(minimize)
        let help = NSMenu(title: L("Help", "帮助")); let helpRoot = NSMenuItem(); helpRoot.submenu = help; main.addItem(helpRoot)
        help.addItem(item(L("Export diagnostics…", "导出诊断…"), "square.and.arrow.up", #selector(exportReport)))
        NSApp.mainMenu = main
    }
    private func updateStatus() {
        guard statusItem != nil else { return }
        if menuLanguage != model.snapshot.settings.language {
            menuLanguage = model.snapshot.settings.language; installMenus()
        }
        if statusItem.isVisible != model.snapshot.settings.showInMenuBar { statusItem.isVisible = model.snapshot.settings.showInMenuBar }
        guard statusItem.isVisible else { return }
        let hasIncident = !model.snapshot.leases.isEmpty || model.snapshot.apps.contains { $0.level >= .critical }
        let symbol = !model.online ? "shield.slash" : !model.snapshot.settings.guardEnabled ? "pause.circle" : hasIncident ? "exclamationmark.shield" : "shield.lefthalf.filled"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Memory Guard")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.title = model.snapshot.settings.showPercentage && model.snapshot.system.valid ? " \(model.snapshot.system.percentage)%" : ""
        statusItem.button?.toolTip = "Memory Guard"
        let menu = NSMenu()
        menu.addItem(item(L("Open Memory Guard", "打开 Memory Guard"), "macwindow", #selector(showWindow)))
        menu.addItem(.separator())
        if !model.snapshot.leases.isEmpty {
            let notice = item(L("\(model.snapshot.leases.count) paused", "\(model.snapshot.leases.count) 个进程已暂停"), "pause.circle", #selector(overview)); menu.addItem(notice)
        }
        let enabled = model.snapshot.settings.guardEnabled
        menu.addItem(item(enabled ? L("Pause protection", "暂停保护") : L("Resume protection", "恢复保护"), enabled ? "pause.shield" : "play.shield", #selector(toggleProtection)))
        menu.addItem(item(L("Settings…", "设置…"), "gearshape", #selector(settings), key: ","))
        menu.addItem(.separator()); menu.addItem(item(L("Quit Interface", "退出界面"), "power", #selector(quitInterface), key: "q"))
        statusItem.menu = menu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
