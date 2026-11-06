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
| `Source/PolicyTests.swift` | 不访问硬件的策略和验证测试 |
| `Source/install.sh` / `uninstall.sh` | 安装、授权绑定和卸载 |
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

后台约每 15 秒检查策略。界面有约 10 秒的常规刷新，并订阅电源变化和唤醒事件；唤醒或成功控制后短暂每秒复查。界面事件刷新不等于固件立即执行。

## 权限边界

安装、更新、卸载通过 macOS 管理员授权执行脚本。日常请求只允许 `configure`、`reset`、`firmware-test` 和只读 `ping`；不会接受调用方指定的可执行路径、任意 shell 或任意 SMC key。

安装时在 root 所有的 `client-identity.plist` 写入当前控制台用户 UID、GUI 和后台 CDHash。双方设置 macOS 代码签名要求。后台仅接受授权账户在当前控制台登录时的请求；执行前再次核对用户。超时不自动重发写入。

这不是多用户授权系统。切换账户、替换或重编译应用后，可能需要重新安装后台绑定。更多边界见[安全政策](../SECURITY.md)。

## 后端

优先使用固件上限 `bfF0` / `bfD0` / `bfE0`，否则检测 `CHTE` 或 `CH0B` + `CH0C` 充电开关。主动放电使用可用的 `CHIE` / `CH0J` / `CH0I`；`AC-W` 用于独立物理电源检测。

适配器实验模式需要显式启用，不能因为普通接口写入失败就自动切换。

首次接管前保存原固件设置；正常交还系统、卸载和失败恢复会尝试还原。失败时应保留恢复条件，不能通过清空配置假装恢复成功。文件锁与原子写入用于串行化和持久化。
