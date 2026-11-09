# CleanUpForMacOS — 未发布 / Unreleased

本文件是下个版本的发布说明草稿，不代表已有新的安装包。当前公开安装包仍为 0.1.0。

## 本次改进

- **扫描结果更可信：** 目录或子目录读取失败会显示错误，不能再被当作零占用或选中清理。
- **扫描可以取消：** 缓存、模拟器和临时构建扫描，以及 Homebrew 只读查询支持取消；取消“扫描全部”后不会继续启动后续类别。
- **长任务状态更清楚：** 显示当前阶段、耗时及最近命令输出。外部命令增加超时处理，避免无限等待。
- **清理前逐项核对：** 缓存和临时构建使用可滚动的确认页，列出每个目标、估算大小、操作方式和清理影响。
- **跳过变化的目标：** 清理前复核目录状态；无法读取或检测到内容变化时，跳过目标并要求重新扫描确认。
- **修复选择冲突：** 同一规则的父目录与子目录不能同时保留选择。
- **增加安全回归测试：** 19 项自动化测试覆盖路径限制、选择冲突、扫描失败、取消、变化检测、符号链接，以及命令输出、超时和终止处理；已接入 CI。

## 安全提醒与已知限制

- 普通缓存和临时构建移到废纸篓；移入废纸篓不代表磁盘空间立即释放。模拟器设备删除仍是永久操作。
- 目录状态复核使用元数据，不读取文件内容，也不是原子文件系统事务。清理前请退出相关应用、结束构建；最终检查后仍可能发生变化。
- 缓存扫描大小仍为估算值，可能不包含隐藏文件。变化检查会检查隐藏条目的元数据，不会把它们显示为文件清单。
- 安装、升级、卸载等变更操作不提供强制取消。超时或停止不代表回滚；Homebrew 会尝试刷新清单，重试前请核对实际状态。独立运行的子进程不保证一同停止。
- 未增加清理规则或扩大允许清理的路径范围，配置格式保持不变。

## 验证与分发状态

- 本机 `swift test`：19 项通过，无失败。
- 本机未签名 Xcode 构建通过；24 条清理规则静态校验及 diff 格式检查通过。
- 测试仅使用临时测试数据和本地测试命令，未执行真实用户目录清理、Homebrew 软件变更或模拟器删除。
- 新确认界面的交互、干净账户完整流程、最低支持系统及各处理器架构仍需人工验收。
- 尚未制作、签名、公证或发布本次改动的新安装包；未创建版本标签。

---

## Improvements

- Failed directory reads now invalidate scans instead of appearing as zero usage or becoming cleanup targets.
- Cache, simulator, and temporary-build scans and read-only Homebrew queries can be cancelled. Cancelling a full scan prevents later categories from starting.
- Long-running work shows its stage, elapsed time, and recent command output. External commands have deadlines instead of waiting indefinitely.
- Scrollable cleanup confirmation sheets list each cache or temporary-build target, estimated size, operation, and impact.
- Cleanup rechecks directory metadata. Changed or unreadable targets are skipped and require a fresh scan and confirmation.
- Parent and descendant selections are mutually exclusive within a rule.
- CI now runs 19 safety regression tests covering path restrictions, selection conflicts, failed/cancelled scans, change detection, symlinks, command output, timeouts, and termination.

## Safety and limitations

- Ordinary cache and temporary-build cleanup move items to Trash, which does not immediately reclaim disk space. Simulator device deletion remains permanent.
- Metadata checks do not read file contents or make cleanup atomic. Quit related apps and stop builds first; changes after the final check remain possible.
- Cache sizes remain estimates and may omit hidden files. Change detection checks hidden-entry metadata without displaying a file inventory.
- Modifying operations have no force-cancel button. Timeout or termination does not imply rollback. Homebrew attempts to refresh inventory after failure; inspect actual state before retrying. Detached descendants may continue running.
- No cleanup rules, approved roots, or configuration schema were changed.

## Verification and distribution

- Local `swift test`: 19 tests passed with no failures.
- Local unsigned Xcode build, static validation of 24 rules, and diff-format checks passed.
- Tests use disposable fixtures and local test commands; no real user cleanup, Homebrew package changes, or simulator deletion was performed.
- Confirmation-sheet interaction, clean-account end-to-end flows, minimum supported systems, and architecture coverage still need manual verification.
- These are draft notes. No new installer was packaged, signed, notarized, or published, and no release tag was created. The current public installer remains 0.1.0.
