# CleanUpForMacOS

**简体中文** | [English](README.en.md)

一个面向开发者的 macOS 存储整理工具。由你主动扫描、检查说明和空间估算、选择目标；普通清理会先移到废纸篓，需要再次确认，不会静默或定时删除。

[下载 CleanUpForMacOS 0.1.0 DMG](https://github.com/13098806890/MacosStorageManager/releases/download/v0.1.0/CleanUpForMacOS-0.1.0.dmg) · [查看所有版本](https://github.com/13098806890/MacosStorageManager/releases)

> **当前版本：** `0.1.0`，已使用 Developer ID 签名并通过 Apple 公证。安装包适用于 macOS 14 或更新版本，不适用于 Mac App Store。

> **安全提示：** 本应用关闭了 App Sandbox，以直接访问配置中批准的用户缓存目录。只导入可信配置，并在每次清理前核对目标和影响。普通缓存清理使用 macOS 废纸篓；模拟器设备删除是永久操作。

## 功能一览

- **按配置扫描缓存：** 扫描由用户发起；可导入多份配置并逐条启用规则。每个配置文件只支持一个角色。
- **先检查再清理：** 查看目录说明、预计影响和大小，展开子目录并按大小排序。每层先显示 10 项，可继续“Load more”或“Load all”。选择目标并确认后，应用将普通缓存目录移到废纸篓。
- **磁盘空间历史：** 展示主目录所在卷的容量，并记录手动扫描后的可用空间变化。历史保存在本机，最多保留 365 个点。
- **模拟器管理：** 查看 Xcode Simulator 设备状态与数据大小。确认删除正在运行的设备时，应用会先将其关机，再永久删除设备及其数据。Runtime 由 Xcode 管理，本应用不直接删除 Runtime 文件。
- **本机记录：** 清理日志、导入配置和磁盘历史保存在本机，不会上传到项目服务。

## 使用方法

从 [GitHub Releases](https://github.com/13098806890/MacosStorageManager/releases) 下载 DMG，打开后将应用拖到 **Applications（应用程序）**。也可以按下方步骤从源码构建。

启动应用后：

1. 打开侧边栏的“配置管理”，启用要扫描的规则，或导入兼容的 JSON 配置。导入规则默认关闭。
2. 回到“全部”，点击顶部的“扫描全部缓存”。类别选择只筛选结果显示；扫描会覆盖所有已启用且本机存在的规则。
3. 检查目录说明、大小和预计影响。展开子文件夹查看大小；每层按空间从大到小排列，默认显示前 10 个。
4. 选择规则目录或已显示的子目录，阅读确认对话框，再选择“移到废纸篓”。
5. 查看 Xcode 设备时打开“模拟器管理”。设备删除不可恢复；Runtime 请前往 Xcode **Settings > Components** 管理。

扫描大小是估算值，不是文件清单；扫描器不读取文件名，且跳过隐藏文件，因此显示值可能低估实际占用。

## 截图

界面截图待补充。截图捕获完成后会放在 [`docs/screenshots/`](docs/screenshots/) 并在此展示；请勿提交包含真实用户名、清理日志、个人文件名或其他本机信息的截图。

## 构建

要求：macOS 14 或更新版本、Xcode 15 或更新版本，并在 Xcode **Settings > Locations** 中选择 Xcode Command Line Tools。

```sh
git clone https://github.com/13098806890/MacosStorageManager.git
cd MacosStorageManager
xcodebuild \
  -project CleanUpForMacOS.xcodeproj \
  -scheme CleanUpForMacOS \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

也可以在 Xcode 中打开 `CleanUpForMacOS.xcodeproj`，选择 `CleanUpForMacOS` scheme 后构建或运行。项目使用直接分发配置，不适用于 Mac App Store。

## 配置与安全边界

内置配置位于 [`Config/cleanup-rules.json`](Config/cleanup-rules.json)。规则是删除提案，不是可信代码，也不代表任意社区建议已通过安全审核。每个 JSON 文件使用相同 schema，用户可导入多份配置并自行启用规则。

规则路径只接受 `$HOME/` 加静态路径组件。运行时还会检查批准的缓存根目录、当前用户主目录边界和符号链接；导入配置不会扩大允许范围。启用规则不能有相同路径或父子路径重叠。普通清理移动到废纸篓，但目标内容仍需由用户判断；模拟器设备删除为永久操作。

扫描只显示规则描述、聚合大小和可见子文件夹，不检查或展示文件清单。更深层子目录使用通用说明；配置中的 `subfolderDescriptions` 只描述直接子文件夹。

添加或修改清理规则前，请先阅读 [`AGENTS.md`](AGENTS.md) 和 [`docs/AI_RULE_AUTHORING.md`](docs/AI_RULE_AUTHORING.md)。规则必须有目录所有者的证据，明确内容、重建方式、离线影响和最小目录边界；目录名含有 `cache`、`tmp` 或 `build` 本身不是安全证据。

## 本机数据与隐私

配置、磁盘空间历史和清理记录保存在当前用户的 Application Support 下的 `CleanUpForMacOS` 目录。清理日志包含解析后的本机绝对路径，请不要提交或公开分享未脱敏的日志。容量数据只用于本机显示；隐私清单见 [`Config/PrivacyInfo.xcprivacy`](Config/PrivacyInfo.xcprivacy)。

## 参与贡献

欢迎提交代码、文档、无障碍和本地化改进，以及有充分证据的规则提案。请先阅读 [`CONTRIBUTING.md`](CONTRIBUTING.md) 和 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)。安全问题请按 [`SECURITY.md`](SECURITY.md) 中的方式报告。

**许可证尚未确定：** 仓库目前没有 `LICENSE` 文件。许可证确定前，代码的再分发和复用条款尚未建立；详情见 [`CONTRIBUTING.md`](CONTRIBUTING.md)。

## 项目维护文档

- [版本策略与发布流程](docs/RELEASING.md)：版本号、构建号、发布检查项与分发签名要求。
- [AI 贡献者指南](docs/AI_CONTRIBUTING.md)：AI 开始修改前必须阅读的项目边界、工作流程和验证要求。
- [清理规则作者指南](docs/AI_RULE_AUTHORING.md)：新增或修改任何清理路径前必须阅读的专门安全规范。
