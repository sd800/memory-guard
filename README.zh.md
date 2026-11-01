<p align="center"><img src="Resources/Assets.xcassets/MemoryGuardIcon.appiconset/icon_128x128.png" width="72" height="72" alt="Memory Guard 星空盾牌"></p>

# Memory Guard

[English](README.md) · macOS 13 及以上 · [MIT 许可证](LICENSE)

Memory Guard 持续观察你选定的 Mac 应用，在内存异常增长时，可以暂停造成增长的那个进程。它最初是为长时间运行的 ChatGPT 和 Codex 任务设计的，也可以守护其他 Mac 应用，每个应用都能单独设置阈值。

## 产品主张（Product statement）

让编程助手继续跑任务，自己切到另一个窗口，是很常见的工作方式。如果某个辅助进程在这段时间里多占用了几个 GiB 的内存，你最先察觉的可能是光标开始卡顿，或者整个系统已经在大量使用交换空间。等到打开活动监视器，仅看当下的数字，很难区分哪个进程一直比较大，哪个才是刚刚失控的。

Memory Guard 会持续记录应用及其已验证的内置辅助进程的内存占用。总量达到你设置的阈值，且连续采样确认增长异常时，它可以暂停具体的异常进程，给你留下处理时间。暂停能阻止该进程继续申请内存，结束进程则能释放它已经占用的内存。

## Codex 的默认保护策略

首次启动时，Memory Guard 会自动添加识别到且签名通过验证的 Codex。推荐阈值按本机物理内存计算。下表以 64 GiB 的 Mac 为例。

| 触发条件 | 默认动作 |
| --- | --- |
| Codex 及其内置进程合计达到 32 GiB，且持续异常增长 | 暂停已验证的、造成增长的进程。 |
| 暂停后两分钟无人处理 | 强制结束该进程。 |
| 合计达到 40 GiB，且确认异常增长和对应进程 | 立即强制结束异常进程。 |

内存占用很高但保持稳定的进程，可以继续运行。强制结束可能丢失当前任务。你可以在**阈值**页修改两个数值，在**应用**页调整超时和紧急处理策略，也可以在**设置**中开启恢复已暂停进程的功能。

## 日常使用

- **选择要守护的应用。** 可以只监控、在异常时通知，或为通过验证的应用组件开启自动保护。发送进程信号前，守护程序会重新核对签名身份和进程启动时间。
- **看清内存变化。** 概览会同时展示最近五分钟的应用内存曲线、系统内存、压力和交换空间。打开可选的菜单栏图标，即可随时看到系统内存占用百分比。
- **减少后台负担。** 采样和暂停记录保存在内存中，日常监控无需定时写入采样文件。默认每两秒采样一次，事件默认保留三天。
- **关掉窗口，继续守护。** 关闭界面后，后台保护会继续运行。在设置里选择**完全退出**，或在应用菜单中选择**退出运行**，即可同时停止两个后台服务。登录时启动可按需开启。

## 构建与运行

在安装了 Xcode 和 macOS SDK 的 Mac 上执行以下命令。项目使用 Swift、AppKit 和 SwiftUI，无第三方包依赖。

```sh
git clone https://github.com/sd800/memory-guard.git
cd memory-guard
bash scripts/build.sh release
mkdir -p "$HOME/Applications"
ditto --norsrc --noextattr "build/Memory Guard.app" "$HOME/Applications/Memory Guard.app"
open "$HOME/Applications/Memory Guard.app"
```

构建产物带有本机签名。更新已有安装时，请先完全退出，再替换应用。运行 `bash scripts/test.sh` 可验证检测和进程控制逻辑。

[构建与安装](docs/BUILD.md) · [检测机制](docs/ARCHITECTURE.md) · [实机验证](docs/VALIDATION.md) · [更新日志](CHANGELOG.md)

## 许可证

© 2026 Songming.org，采用 [MIT 许可证](LICENSE)。
