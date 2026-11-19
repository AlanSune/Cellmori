# 构建与测试

## 环境

使用 Apple Silicon Mac、Xcode Command Line Tools 和 macOS 15.x。已知开发工具链为 Swift 6.1.2。构建脚本使用当前宿主架构，不支持从 Intel 主机直接构建后当作 arm64 安装包发布。

```sh
xcode-select --install
```

工具已安装时无需重复执行。系统框架包括 Foundation、AppKit、SwiftUI、Charts、IOKit、SystemConfiguration、CryptoKit 和 ServiceManagement；无第三方包依赖。

## 检查

在仓库根目录运行：

```sh
bash test.sh
bash test-adapter.sh
bash test-sleep.sh
bash test-installer.sh
bash test-updates.sh
bash test-ui.sh
```

测试覆盖策略、服务状态、供电显示、临时流程文案及请求参数验证。测试不读取或写入 SMC、不安装服务、不发起 XPC 控制。策略检查之外，适配器与睡眠控制测试分别模拟共享寄存器和系统设置，不执行实际 pmset 写入。它们不能代替真实设备的睡眠、充放电和恢复测试。

## 应用

```sh
bash build.sh
```

产物为 `Cellmori.app`，中间文件为 `.build/`。脚本编译 GUI、后台、图标生成器，复制安装/卸载脚本和 LICENSE，并以 ad-hoc 签名启用 Hardened Runtime。构建不会运行 GUI、安装后台或更改电源策略。

## PKG

```sh
bash build-installer.sh
```

先构建应用，再生成 `dist/Cellmori-0.6.9-arm64.pkg`。安装器中间目录默认为 `.installer-build/`，可用 `CELLMORI_PACKAGE_WORK` 环境变量指定其他位置。

```sh
CELLMORI_PACKAGE_WORK="$PWD/.installer-build" bash build-installer.sh
shasum -a 256 dist/Cellmori-0.6.9-arm64.pkg
```

安装包不自动签署或公证。若正式签名，需要使用自己的 Apple Developer 证书；先完成最终应用/后台签名，再生成 PKG，避免安装清单中的哈希与最终文件不一致。后台绑定安装时的应用与后台代码哈希，重建后应更新绑定。

不要提交 `.build/`、`.installer-build/`、`.app` 或 PKG 到源码仓库。二进制发行文件放在 GitHub Releases。

## 界面与安装回归

`bash test-ui.sh` 使用不显示到桌面的 AppKit 窗口，核对菜单面板先关闭再打开主界面、其他窗口不被关闭、缺少窗口引用、窗口引用生命周期，以及手柄在点击编辑器外或窗口失焦时取消选中。

`bash render-screenshots.sh` 通过实际应用视图与演示模型生成 `docs/images/` 配图。脚本核对小窗九种状态的窗口尺寸与位置、主窗口与小窗的三列指标居中、范围双向平移、20 个百分点时继续向左拖动和撤销草稿，以及强制深色或浅色后切回跟随系统时的实际画面颜色。还会渲染窄窗口的下载完成与安装指引状态。传入输出目录可把结果保存到临时位置。

`bash test-updates.sh` 使用模拟 HTTP 响应和临时文件检查版本选择、来源、校验、篡改、安装权限拒绝与设置跳转分支。取消打开和文件读取失败不能误判为安装来源拦截。


发布前实机检查两处双手柄的点选、单端拖动、蓝色区段双向拖动、撤销修改、取消选中及切页恢复，确认小窗显示「充电后台服务」和正确标识。在目标 macOS 版本打开「隐私与安全性」，核对入口确实落在对应页面。使用从发布页下载的 PKG 检查系统来源提示、管理员认证和安装后应用与后台。自动测试使用演示界面和模拟错误，实机检查覆盖 macOS 实际提示及交互。

`bash test-installer.sh` 在临时目录使用隔离子进程测试等待期限、健康/阻塞交接、停止失败、安全恢复失败、并发文件锁和进程退出后的锁释放。不会操作真实 launchd 服务或写入硬件。真实旧后台死锁升级验证需要管理员授权；其方法、恢复结果和限制见 VALIDATION.md。
