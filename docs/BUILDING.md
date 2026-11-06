# 构建与测试

## 环境

使用 Apple Silicon Mac、Xcode Command Line Tools 和 macOS 15.x。已知开发工具链为 Swift 6.1.2。构建脚本使用当前宿主架构，不支持从 Intel 主机直接构建后当作 arm64 安装包发布。

```sh
xcode-select --install
```

工具已安装时无需重复执行。系统框架包括 Foundation、AppKit、SwiftUI、Charts、IOKit、SystemConfiguration 和 ServiceManagement；无第三方包依赖。

## 检查

在仓库根目录运行：

```sh
bash test.sh
```

测试覆盖策略、服务状态、供电显示、临时流程文案及请求参数验证。测试不读取或写入 SMC、不安装服务、不发起 XPC 控制。当前有 102 项检查。它们不能代替真实设备的睡眠、充放电和恢复测试。

## 应用

```sh
bash build.sh
```

产物为 `Cellmori.app`，中间文件为 `.build/`。脚本编译 GUI、后台、图标生成器，复制安装/卸载脚本和 LICENSE，并以 ad-hoc 签名启用 Hardened Runtime。构建不会运行 GUI、安装后台或更改电源策略。

## PKG

```sh
bash build-installer.sh
```

先构建应用，再生成 `dist/Cellmori-0.6.0-arm64.pkg`。安装器中间目录默认为 `.installer-build/`，可用 `CELLMORI_PACKAGE_WORK` 环境变量指定其他位置。

```sh
CELLMORI_PACKAGE_WORK="$PWD/.installer-build" bash build-installer.sh
shasum -a 256 dist/Cellmori-0.6.0-arm64.pkg
```

安装包不自动签署或公证。若正式签名，需要使用自己的 Apple Developer 证书；先完成最终应用/后台签名，再生成 PKG，避免安装清单中的哈希与最终文件不一致。后台绑定安装时的应用与后台代码哈希，重建后应更新绑定。

不要提交 `.build/`、`.installer-build/`、`.app` 或 PKG 到源码仓库。二进制发行文件放在 GitHub Releases。
