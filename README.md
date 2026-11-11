# CleanUpForMacOS

**简体中文** | [English](README.en.md)

![CI](https://github.com/13098806890/MacosStorageManager/actions/workflows/ci.yml/badge.svg) [![最新版本](https://img.shields.io/github/v/release/13098806890/MacosStorageManager)](https://github.com/13098806890/MacosStorageManager/releases)

![CleanUpForMacOS app icon](Assets/Assets.xcassets/AppIcon.appiconset/AppIcon-128.png)

CleanUpForMacOS 是一款面向开发者的 macOS 存储整理工具。它帮助你检查开发缓存、Xcode 模拟器和临时构建目录，也能管理 Homebrew formula。扫描由你发起；普通清理先显示估算和影响，并在确认后移到废纸篓。

[下载 macOS 应用](https://github.com/13098806890/MacosStorageManager/releases/download/v0.1.0/CleanUpForMacOS-0.1.0.dmg) · [所有版本](https://github.com/13098806890/MacosStorageManager/releases) · [报告问题](https://github.com/13098806890/MacosStorageManager/issues)

当前稳定版本为 **0.1.0**，适用于 **macOS 14 或更新版本**，已使用 Developer ID 签名并通过 Apple 公证。应用采用直接分发方式，不适用于 Mac App Store。

## 功能

- **开发缓存清理：** 手动扫描配置中的缓存目录，检查用途说明、清理影响和估算大小，再选择目标。目录可展开查看子目录；普通清理需确认并移到废纸篓。
- **多份清理配置：** 导入、导出配置并逐条启用规则。导入的规则默认关闭，每个配置文件只包含一个角色。
- **Xcode 模拟器管理：** 查看设备、数据与运行时占用。删除设备会永久移除设备及其数据；运行时需确认后通过 `simctl` 删除，仍有关联设备时不能移除，之后可从 Xcode 重新下载。
- **临时构建目录：** 检查 `/private/tmp` 下当前用户拥有、含大量编译产物的直接子目录。选中并确认后移到废纸篓；后续构建可能需要重新生成产物。
- **Homebrew 管理：** 手动刷新 formula 清单，查看版本与安装大小，并搜索、安装、升级、固定/解除固定或卸载。每项软件变更均需确认。
- **磁盘空间与本机记录：** 查看主目录所在卷的容量和手动扫描后的可用空间历史。配置、历史和清理记录保存在本机。

## 界面预览

![CleanUpForMacOS 空间总览](docs/screenshots/storage-overview.png)

## 下载和使用

从 [GitHub Releases](https://github.com/13098806890/MacosStorageManager/releases) 下载 DMG，打开后将应用拖到 **Applications（应用程序）**。首次使用时，在“配置管理”中启用需要的规则，回到“全部”并手动开始扫描。仔细阅读目标说明、估算和确认对话框后再操作。

扫描大小是估算值，不是文件清单。扫描器不会展示文件名，并跳过隐藏文件，因此大小可能低于目录实际占用。清理前会复核扫描时记录的目录元数据；读取失败、扫描期间内容变化或目标已变化时，不会继续使用旧结果，必须重新扫描。普通缓存与临时构建清理会移到废纸篓；模拟器设备删除为永久操作。

## 安全与隐私

本应用关闭 App Sandbox，以访问已批准的用户缓存目录，并提供固定的 `/private/tmp` 临时构建管理功能。清理路径限定为 `$HOME/` 下的静态路径，并在运行时检查批准的缓存根目录、主目录边界和符号链接；导入配置不能扩大允许范围。不要导入不可信配置，也不要仅凭目录名判断内容可删除。

本机配置、磁盘历史和清理记录存储在当前用户的 Application Support 中。清理日志包含解析后的本机绝对路径，请勿公开分享未脱敏日志。安全验证边界见 [`docs/SAFETY_VALIDATION.md`](docs/SAFETY_VALIDATION.md)；清理规则编写要求见 [`AGENTS.md`](AGENTS.md) 和 [`docs/AI_RULE_AUTHORING.md`](docs/AI_RULE_AUTHORING.md)。隐私清单见 [`Config/PrivacyInfo.xcprivacy`](Config/PrivacyInfo.xcprivacy)。

## 从源码构建

需要 macOS 14 或更新版本、Xcode 15 或更新版本，并在 Xcode **Settings > Locations** 中选择 Xcode Command Line Tools。

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

也可以用 Xcode 打开 `CleanUpForMacOS.xcodeproj`，选择 `CleanUpForMacOS` scheme 后构建或运行。GitHub Actions 会校验内置配置、运行安全回归测试并构建 macOS 应用；普通提交不会自动发布新版本。

## 仓库结构

```text
Sources/
├── App/                         # 应用入口、窗口与主导航
├── OperationSupport.swift      # 操作取消、命令运行和目录指纹
└── Features/
    ├── Cleanup/                 # 缓存规则、扫描/清理状态与相关视图
    ├── Homebrew/                # Homebrew 清单、操作与界面
    ├── Simulator/               # 模拟器设备和运行时管理
    └── TemporaryBuilds/         # 临时构建目录扫描与管理
Config/                           # 内置规则和隐私清单
Assets/                           # App 图标资源
scripts/                          # 配置校验工具
Tests/                            # 清理安全回归测试
.github/workflows/                # GitHub Actions CI
docs/                             # 架构、安全验证、发布和版本文档
```

## 贡献与项目文档

欢迎提出代码、文档、无障碍、本地化和有证据支持的清理规则改进。开始前请阅读 [`CONTRIBUTING.md`](CONTRIBUTING.md)、[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) 和 [`SECURITY.md`](SECURITY.md)。版本号、发布步骤及签名要求见 [`docs/RELEASING.md`](docs/RELEASING.md)。

**许可证尚未确定：** 仓库目前没有 `LICENSE` 文件，代码再分发和复用条款尚未建立，因此本项目暂不声明为已授权复用的开源软件。
