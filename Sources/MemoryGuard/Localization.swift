import Foundation
import MemoryGuardKit

enum Texts {
    static var language: AppLanguage = .system
    static var chinese: Bool {
        if language == .chinese { return true }
        if language == .english { return false }
        if let index = CommandLine.arguments.firstIndex(of: "--language"), CommandLine.arguments.count > index + 1 {
            return CommandLine.arguments[index + 1].hasPrefix("zh")
        }
        return Locale.preferredLanguages.first?.hasPrefix("zh") == true
    }
    static func get(_ english: String, _ chinese: String) -> String { self.chinese ? chinese : english }
    static func level(_ value: Level) -> String {
        switch value {
        case .normal: return get("Normal", "正常")
        case .warning: return get("Warning", "预警")
        case .high: return get("High", "高位")
        case .critical: return get("Critical", "危险")
        case .emergency: return get("Emergency", "紧急")
        }
    }
    static func mode(_ value: Mode) -> String {
        switch value {
        case .monitor: return get("Monitor", "仅监控")
        case .alert: return get("Monitor & alert", "监控与通知")
        case .protect: return get("Auto protect", "自动保护")
        }
    }
    static func message(_ key: String) -> String {
        switch key {
        case "offline": return get("Connecting to guard…", "正在连接守护服务…")
        case "quitWithPausedProcesses": return get("Resolve the paused processes in Overview before quitting.", "请先在概览中处理已暂停的进程，再完全退出。")
        case "shutdownFailed": return get("Could not stop background protection. Try quitting again.", "未能停止后台保护，请再次尝试完全退出。")
        case "serviceRegistrationFailed": return get("Could not restore background protection. Reopen Memory Guard.", "未能恢复后台保护，请重新打开 Memory Guard。")
        case "invalidApp": return get("Choose a valid macOS application.", "请选择有效的 macOS 应用。")
        case "alreadyAdded": return get("This application is already protected.", "此应用已在保护名单中。")
        case "monitorOnlyIdentity": return get("Identity unverified · monitoring only", "身份未验证 · 仅监控")
        case "samplingDenied": return get("Some processes cannot be sampled.", "部分进程无法读取。")
        case "trackingLimit": return get("Process limit reached · automatic actions paused", "进程数量达到上限 · 自动操作已暂停")
        case "interventionLoop": return get("Repeated incidents · automatic actions on cooldown", "异常反复触发 · 自动操作冷却中")
        case "signalFailed": return get("Process control failed. No elevated access was requested.", "进程操作失败，未请求提权。")
        case "identityChanged": return get("Process identity changed. Action cancelled.", "进程身份已变化，操作已取消。")
        case "resumeDisabled": return get("Resuming is off. End the paused process in Overview.", "恢复功能已关闭。请在概览中结束已暂停的进程。")
        case "expiredAction": return get("This incident has already ended.", "此次事件已结束。")
        case "storageFailed": return get("Cannot save guard state. Protection is unavailable.", "无法保存守护状态，保护暂不可用。")
        case "recoveryUnavailable", "recoveryFailed": return get("Recovery needs attention. Automatic pause is unavailable.", "恢复服务需要处理，自动暂停暂不可用。")
        case "invalidSettings": return get("Check the protection settings and threshold order.", "请检查保护设置及阈值顺序。")
        case "frozen": return get("Process paused", "已暂停异常进程")
        case "resumed": return get("Process resumed", "已恢复进程")
        case "recovered": return get("Recovered after guard interruption", "守护服务中断后已恢复进程")
        case "terminated": return get("Process ended", "已结束进程")
        case "emergencyKilled": return get("Emergency · process ended", "紧急保护 · 已结束进程")
        case "timeoutKilled": return get("No response · process ended", "处理超时 · 已结束进程")
        case "warning": return get("Memory warning", "内存预警")
        case "critical": return get("Memory is critically high", "内存达到危险等级")
        case "hold": return get("Countdown cancelled · still paused", "已取消倒计时 · 保持暂停")
        case "quit": return get("Exit requested", "已请求退出")
        case "guardRestart": return get("Guard restarted to reclaim its memory", "守护服务已重启以回收自身内存")
        default: return get("The operation could not be completed.", "未能完成操作。")
        }
    }
}
func L(_ english: String, _ chinese: String) -> String { Texts.get(english, chinese) }
func memory(_ bytes: Double) -> String { String(format: "%.1f GiB", bytes / GiB) }
