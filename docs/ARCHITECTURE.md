# 架构与权限

## 组件

| 文件 | 职责 |
| --- | --- |
| `Source/App.swift` | SwiftUI 界面、菜单栏、趋势、导出、登录启动、错误弹窗 |
| `Source/Shared.swift` | 数据模型、纯策略、供电显示、固件目标和状态编码 |
| `Source/ControlChannel.swift` | XPC 协议、请求白名单、签名绑定及账户检查 |
| `Source/Helper.swift` | root 后台、命令执行、策略循环、恢复及睡眠处理 |
| `Source/SMC.c` / `SMC.h` | 固定范围的 SMC 探测、读写和回读验证 |
| `Source/ServiceStatus.swift` | launchd、进程、心跳与版本的只读检查 |
| `Source/MenuBarIcon.swift` | 菜单栏模板图标与百分比 |
| `Source/MakeIcon.swift` | 本地绘制应用图标 |
| `Source/UpdateService.swift` | GitHub 正式版本选择、资源来源验证、下载与 SHA-256 校验 |
| `Source/AppUpdater.swift` | 更新状态、可选自动检查、取消下载及系统安装器交接 |
| `Source/MenuPanelNavigation.swift` | 捕获菜单面板窗口，先关闭发起跳转的面板，再显示主界面 |
| `Source/PolicyTests.swift` | 不访问硬件的策略和验证测试 |
| `Source/install.sh` / `uninstall.sh` | 安装、授权绑定和卸载 |
| `Source/installer-support.sh` | 有时限的升级交接、停止旧服务与安全恢复协调 |
| `Packaging/` | PKG 组件、安装页面和安装器检查 |

## 系统标识

| 项目 | 值 |
| --- | --- |
| 应用 Bundle ID | `io.cellmori.app` |
| GUI 可执行文件 | `Cellmori.app/Contents/MacOS/Cellmori` |
| 后台服务 | `io.cellmori.helper` |
| XPC Mach service | `io.cellmori.helper.control` |
| 后台文件 | `/Library/PrivilegedHelperTools/io.cellmori.helper` |
| launchd 文件 | `/Library/LaunchDaemons/io.cellmori.helper.plist` |
| root 数据 | `/Library/Application Support/Cellmori/` |
| 个人历史 | `~/Library/Application Support/Cellmori/history.json` |

## 数据流

界面直接读取实时电池和系统供电来源，通过 XPC 提交控制请求。后台验证调用方，串行执行固定操作，将策略与状态写入 root 数据目录。界面读取心跳，并用 launchd 的 PID、服务名称、版本和响应时间核对服务。

后台约每 15 秒检查策略。界面有约 10 秒的常规刷新，并订阅电源变化和唤醒事件；唤醒或成功控制后短暂每 250 毫秒复查。界面事件刷新不等于固件立即执行。

## 权限边界

安装、更新、卸载通过 macOS 管理员授权执行脚本。日常请求只允许 `configure`、`reset`、`firmware-test` 和只读 `ping`；不会接受调用方指定的可执行路径、任意 shell 或任意 SMC key。

安装时在 root 所有的 `client-identity.plist` 写入当前控制台用户 UID、GUI 和后台 CDHash。双方设置 macOS 代码签名要求。后台仅接受授权账户在当前控制台登录时的请求；执行前再次核对用户。超时不自动重发写入。

这不是多用户授权系统。切换账户、替换或重编译应用后，可能需要重新安装后台绑定。更多边界见[安全政策](../SECURITY.md)。

## 后端

优先使用固件上限 `bfF0` / `bfD0` / `bfE0`，否则检测 `CHTE` 或 `CH0B` + `CH0C` 充电开关。主动放电使用可用的 `CHIE` / `CH0J` / `CH0I`；`AC-W` 用于独立物理电源检测。

适配器兼容限充在 0.6.9 移除。旧配置先恢复外接供电及睡眠设置，再迁回 macOS 管理，保留保存的目标值；恢复失败会保留迁移意图并重试。正常的接电放电仍使用适配器控制。

首次接管前保存原固件设置；明确交还系统或卸载时尝试还原。临时控制失败保留用户策略、恢复日常固件上限并停止主动放电，下个周期重试；不能通过清空配置假装恢复成功。文件锁与原子写入用于串行化和持久化。

0.6.4 的主动放电交接：先验证适配器禁用请求，再临时释放固件上限，固件设置变化后再次确认适配器请求。自动达到目标、合盖暂停、温度暂停或出错时，先恢复日常上限再恢复适配器；睡眠前设置保守固件上限，并读回确认。实机短测中，同时开启固件限充与 CHIE 放电时系统仍报告 AC Power，关闭固件限充后才切到 Battery Power；该结果不代表所有机型都存在此冲突。

CHIE 读取的是共享状态位，只比较本程序使用的 bit 3，不清除其他接口请求，也不把其他位当作本程序写入失败。不能将 CH0J 读到的共享状态字节直接写回作为恢复值。系统供电图标继续使用 macOS 的供电来源，不根据负电流或已提交指令推断已切换供电。

`bash test-adapter.sh` 使用模拟控制器执行实际 C 读写逻辑，不访问真实 SMC；覆盖共享位保留、重复写入抑制、硬件拒绝请求和固件严格读回。


## 合盖放电与睡眠恢复（0.6.6）

`configure` 可选第六项只允许 `0`/`1`，旧五项请求默认关闭保持唤醒；旧配置缺少可选字段同样关闭。只有用户选中开关、物理电源可确认且纯策略确认需要主动放电时，后台才通过固定 `/usr/bin/pmset` 参数临时设置 `disablesleep`。写入和读回确认失败时不允许合盖放电。不会使用用户提供的可执行路径、shell 字符串或 pmset 参数。

先将原 SleepDisabled 标志与时间写入 root 的 `sleep-recovery.json`，再改变系统设置。实际接管先于适配器切断；结束时顺序为固件上限、适配器、睡眠恢复。原标志为 1 时不在释放时清零；恢复记录仅在确认恢复后删除。此全局标志不是系统提供的多进程引用计数，无法识别接管期间其他程序对同一全局标志的新占用。

正常结束、暂停、停止、断电、错误、更新和卸载路径均释放接管。launchd 自动重启后台时，先恢复供电与原睡眠标志，再重新评估保存的任务。恢复失败保留标记并重试，不假称成功。直接由管理员卸载 launchd、阻止服务重启、系统故障或手动删除恢复记录不属于已保证的恢复路径；不要在任务接管时删除系统文件。

`bash test-sleep.sh` 模拟系统原状态、持久化与读写错误、进程崩溃后恢复、温度暂停、断电、超时及达到目标的交接。真实合盖及睡眠/唤醒仍需实机验收。


## 死锁与更新恢复（0.6.8）

睡眠设置调用使用 posix_spawn、非阻塞输出和 waitpid(WNOHANG)，避免 Foundation Process.waitUntilExit 在策略锁持有期间驱动主循环并嵌套触发定时任务。子进程有单调时钟期限、输出上限及失败回收。

安装器使用单独的系统文件锁串行化安装，锁描述符关闭或进程退出即释放；与后台的策略锁分开。先给旧后台交接 5 秒时限，随后停止旧 launchd 服务；停止也有时限，必要时请求 launchd 终止旧服务。新工具再次执行 prepare-update，确认保存的上限、适配器交接和睡眠恢复后才替换后台及通信身份、注册新进程。第二次安全交接失败会明确中止，不报告安装成功。安装不等同于丢弃用户策略或强行恢复默认设置。

PKG 在替换应用前结束当前控制台用户的旧界面，安装后验证新后台的 PID、服务名称和版本，再以该用户身份重新打开应用。
