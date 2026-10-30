# CleanUpForMacOS

CleanUpForMacOS 是一个开源 macOS 存储整理工具。用户主动选择配置并扫描目录，查看空间估算、内容说明和删除影响，再逐项选择并确认操作。普通清理规则会把所选目录移到 macOS 废纸篓；应用不会定时或静默清理。

> **安全说明：** 应用关闭了 App Sandbox，以便直接访问配置中批准的用户缓存目录。请只导入你信任的配置；导入规则仍会经过应用内的路径校验。任何清理操作都必须由用户选择并确认。

## 功能

### 清理配置

- 内置程序员缓存配置，并可导入多份符合相同 JSON schema 的配置。
- 在“配置管理”中按配置查看规则，逐条启用或停用；启用的规则会出现在扫描列表中。
- 扫描全部已启用规则、某个类别或单条规则。扫描由用户主动发起。
- 扫描结果显示配置作者提供的目录说明、预计删除影响和目录大小。若目标目录有直接子文件夹，可展开查看每个直接子文件夹的名称、大小和配置说明，并单独选择清理。
- 选择规则后再次确认，应用将目标移到废纸篓。清理结果、规则 ID、说明、大小和解析后的本机路径会写入本地操作日志。

### 磁盘空间历史

- 显示用户主目录所在卷的总容量、已用容量和可用容量。
- 每次手动扫描完成后保存一个可用空间数据点，并以折线图展示时间变化。模拟器清单扫描也会记录一个点。
- 历史只保存在本机，最多保留最近 365 个扫描点。

### Xcode 模拟器

- 模拟器设备与普通缓存规则分开管理。应用从 `xcrun simctl list --json` 读取设备清单、状态和数据/日志大小。
- 用户可选择关机设备，确认后应用通过固定的 `xcrun simctl delete <validated-UUID>` 操作删除设备。设备中的 App、App 数据和设置会被永久删除，这项操作不会移到废纸篓。
- 共享 Simulator Runtime 会显示名称和可用状态。Runtime 的检查、安装和移除由 Xcode 的 **Settings > Components** 管理；本应用不直接删除 Runtime 文件。

## 下载与运行

### 环境要求

- macOS 14 或更新版本。
- Xcode 15 或更新版本。
- Xcode Command Line Tools 已安装，并在 Xcode 的 **Settings > Locations** 中选定。

### 使用 Xcode 构建

1. 克隆本仓库并打开 `CleanUpForMacOS.xcodeproj`。
2. 选择 `CleanUpForMacOS` scheme 和本机 macOS 运行目标。
3. 运行或构建应用。

### 使用命令行构建

```sh
xcodebuild \
  -project CleanUpForMacOS.xcodeproj \
  -scheme CleanUpForMacOS \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

使用 Xcode 构建目录中的 `CleanUpForMacOS.app` 启动应用。此项目采用直接分发配置，不适用于 Mac App Store。

## 首次使用

1. 在侧边栏打开“配置管理”。内置配置默认启用；如需其它开发工具的清理规则，使用“导入 JSON 配置”选择一个或多个配置文件。
2. 在每份配置中逐条启用你需要的规则。导入的配置默认不启用任何规则。
3. 回到“全部”或具体类别，点击“扫描”或单条规则旁的扫描按钮。
4. 阅读目录说明、预计影响和扫描大小；需要时展开查看直接子文件夹。
5. 选择要清理的目录或子文件夹，阅读确认对话框后选择“移到废纸篓”。
6. 查看模拟器时打开“模拟器管理”。不要运行中的设备可以在确认后通过 `simctl` 删除；Runtime 请前往 Xcode **Settings > Components** 管理。

扫描大小是估算值，不代表完整文件清单。清理前请确认说明和目标范围符合你的工作流。

## 配置文件

内置社区配置位于 [`Config/cleanup-rules.json`](Config/cleanup-rules.json)。每个 JSON 文件是一个角色配置；用户可以导入多份配置，并从中挑选需要加入扫描列表的规则。规则 ID 需要在所属配置文件内唯一，不同配置里的规则 ID 可以相同，因为应用使用配置 ID 与规则 ID 的组合区分运行时规则。

配置结构：

```json
{
  "schemaVersion": 1,
  "configVersion": "2026.10.0",
  "role": "programmer",
  "rules": [
    {
      "id": "xcode-derived-data",
      "role": "programmer",
      "title": "Xcode DerivedData",
      "path": "$HOME/Library/Developer/Xcode/DerivedData",
      "summary": "Xcode 的构建产物、索引和中间文件。",
      "impact": "Xcode 会在后续构建时重新生成相关文件；首次构建和索引可能变慢。",
      "risk": "low",
      "category": "Xcode",
      "subfolderDescriptions": {
        "ModuleCache.noindex": "Swift 和 Clang 构建使用的模块缓存。"
      }
    }
  ]
}
```

`subfolderDescriptions` 是可选字段，只能描述扫描时发现的**直接子文件夹**；它不会创建路径或扩大授权范围。示例仅说明字段结构，不能替代为新路径收集安全证据。

### 路径和安全限制

- 只允许 `$HOME/` 加静态目录组件，例如 `$HOME/Library/Caches/example-tool`。
- 禁止真实用户名、机器绝对路径、`~`、其他变量、通配符、Shell 表达式、空组件、`.` 和 `..`。
- App 只接受 `Sources/CleanupStore.swift` 中明确批准的缓存根目录。导入 JSON 不会扩大这些根目录。
- 扫描和清理会拒绝目标符号链接，并检查解析后的目标仍在当前用户主目录和批准根目录中。
- 启用规则之间不能存在重复路径或父子路径重叠，避免先清理父目录后子目录目标失效。
- 配置只是删除提案，不是可信代码。字段不能触发命令、脚本或网络下载。

添加或修改规则前，必须阅读 [`AGENTS.md`](AGENTS.md) 和 [`docs/AI_RULE_AUTHORING.md`](docs/AI_RULE_AUTHORING.md)。AI 和人工贡献者都要确认路径所有者、实际内容、可重建性、目录边界、版本范围和用户影响。只凭路径名里含有 `cache`、`tmp` 或 `build` 不足以证明可删除。

## 扫描和清理的限制

- 扫描器显示规则说明和聚合大小，不会检查文件名，也不会识别目录中的具体文件内容。
- 扫描器跳过隐藏文件；显示大小可能低估实际占用。
- 子文件夹列表只展示目标的直接子文件夹，子文件夹大小是递归估算值；不跟随符号链接。
- 清理会移动整个配置目录或一个已扫描到的直接子目录。应用不会在点击确认前再次核对目录内容是否变化。
- 移到废纸篓为普通清理提供恢复机会，但不代表目标一定安全；Simulator 设备删除是不可通过本应用恢复的操作。
- Runtime 大小和可回收空间由 Xcode 展示；应用不会扫描或删除 Runtime 包。

## 本机数据与隐私

数据位于当前用户的 Application Support 目录下的 `CleanUpForMacOS` 文件夹：

- `profiles.json`：导入的脱敏配置和启用状态。
- `disk-space-history.json`：最近的磁盘可用空间历史点。
- `cleanup-log.jsonl`：清理操作日志，包含解析后的本机绝对路径。

这些文件不会写入仓库。请勿公开分享未经脱敏的 `cleanup-log.jsonl`。应用没有把这些本地记录同步或上传到项目服务的功能。容量信息仅用于本地显示；Privacy Manifest 声明见 [`Config/PrivacyInfo.xcprivacy`](Config/PrivacyInfo.xcprivacy)。

关闭 App Sandbox 能让应用直接读取允许的缓存路径，减少用户逐目录授权步骤；同时也意味着应用进程具备更广泛的文件访问能力。请只从可信来源导入配置，并检查每次清理的目标和说明。本项目面向自行构建或直接分发，不支持 Mac App Store 分发。

## 贡献

欢迎通过 Pull Request 贡献新的角色配置和清理规则。请让每个配置保持路径脱敏，并在 Pull Request 描述中附上规则对应的权威证据、重建方式、影响说明和风险判断。不要提交用户的绝对路径、操作日志、Security-Scoped Bookmark、构建产物或其他本机数据。

详细的 AI 规则编写说明：[`docs/AI_RULE_AUTHORING.md`](docs/AI_RULE_AUTHORING.md)。

## 许可证

仓库当前尚未包含 `LICENSE` 文件。维护者确定并添加许可证后，贡献者和使用者再按该许可证分发或复用代码。
