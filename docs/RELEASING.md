# GitHub 上传与发布

## 上传源码

此目录就是仓库根目录。不要上传其上级 `outputs/`、本机 `work/`、旧源码归档、个人状态文件或安装后的 root 数据。

先在 GitHub 创建空仓库，不自动添加另一份 README 或许可证。然后在本目录执行：

```sh
git init -b main
git add .
git diff --cached --stat
git diff --cached
```

检查暂存内容后提交：

```sh
git commit -m "Initial open-source release of Cellmori"
```

再执行 GitHub 新仓库页面显示的 `git remote add origin ...` 和 `git push -u origin main` 命令。仓库 URL 以你自己的账号和项目为准，本文不预设账号或代为上传。

GitHub 网页上传时，应上传此目录内部文件，使 LICENSE 与 README.md 位于仓库根目录。普通拖放可能漏掉 `.github/` 等隐藏文件，建议用 Git 提交。

## 发布前检查

- 核对 `LICENSE` 中版权署名 “Cellmori contributors” 符合维护者实际安排；保留标准 MIT 条文。
- 核对新增代码、图标和引用材料的来源许可；MIT 不能覆盖未经授权的第三方内容。
- 检查名称与目标市场的商标风险；公开检索无结果不是权利保证。
- 确认 Source/Shared.swift 的应用/后台版本、build.sh 的版本和 CHANGELOG 一致。
- 运行 `bash test.sh`、`bash build.sh`、`bash build-installer.sh`。
- 确认没有个人绝对路径、密码、密钥、证书、设备序列号、历史采样和 root 配置。
- 启用 GitHub 私密漏洞报告。没有安全邮箱时不要虚构联系方式。
- 分别记录新装、升级、停止、交还系统、卸载、睡眠/唤醒与故障恢复的实际验证结果；未测试的明确标注。
- 区分 MacBook Pro / macOS 26 的用户反馈、本次回归检查与其他设备未验证的场景。

## PKG 与 Releases

二进制放 GitHub Releases，不提交进 Git 历史。构建生成的是未签名、未公证 PKG，应用和后台使用本地 ad-hoc 签名。

```sh
(cd dist && shasum -a 256 Cellmori-0.6.2-arm64.pkg > Cellmori-0.6.2-arm64.pkg.sha256)
```

创建 `v0.6.2` 标签和 Release 时，上传 PKG 与校验文件，附上对应提交、支持范围、签名状态、已知限制和验证结果。本次按维护者要求发布正式 Release；没有 Developer ID 签名与公证的事实仍须明确披露。

正式 Developer ID 签名和公证需要维护者自己的证书及账号。当前脚本未实现自动公证。最终签名在打包之前完成，避免签名绑定或安装清单哈希失配；不要把证书或密钥放入仓库。

## 当前验证记录

见 [VALIDATION.md](VALIDATION.md)。它记录本次实际执行的检查，不替代硬件验收。
