# 第三方依赖、资料与许可边界

## 构建依赖

本仓库没有 Swift Package、CocoaPods、Homebrew 运行时库或随包分发的第三方二进制依赖。构建使用 Apple SDK 和系统框架；SDK 与系统组件遵循 Apple 各自的条款，不因本仓库 MIT 许可而被重新授权。

## 研发参考资料

以下链接用于解释硬件接口、既有工具或研究背景；参考链接不表示这些项目为本项目背书，也不表示其代码已按 MIT 重新授权。

- [actuallymentor/battery](https://github.com/actuallymentor/battery)
- [charlie0129/batt](https://github.com/charlie0129/batt)
- [hholtmann/smcFanControl](https://github.com/hholtmann/smcFanControl)
- [Apple Code Signing Guide](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/RequirementLang/RequirementLang.html)
- [Apple XPC 文档](https://developer.apple.com/documentation/foundation/nsxpcconnection)

项目原始开发说明将当前实现描述为独立实现；本次发布整理没有将上述仓库文件、脚本或可执行文件复制进来。本说明不是完整的代码来源或知识产权审计。若维护者识别出实际衍生代码，应在发布前核对其许可证、保留版权与许可声明，并解决任何许可冲突。

## 图标与名称

应用图标由 `Source/MakeIcon.swift` 本地绘制；菜单栏图标由 `Source/MenuBarIcon.swift` 绘制。界面使用系统符号与系统框架，相关平台条款仍适用。

不随本项目分发第三方产品图标、截图或品牌资产。Apple、macOS、AlDente 等名称只用于说明平台或比较背景，不表示隶属或授权。Cellmori 名称的公开检索不是商标可用性保证，见 docs/NAMING.md。
