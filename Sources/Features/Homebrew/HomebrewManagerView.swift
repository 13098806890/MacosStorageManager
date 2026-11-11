import SwiftUI


@MainActor
struct HomebrewManagerView: View {
    @State private var store: HomebrewManagerStore
    @State private var pendingAction: HomebrewAction?

    init(store: HomebrewManagerStore) {
        _store = State(initialValue: store)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Homebrew 命令行工具")
                    .font(.title2.weight(.semibold))
                Text("查看和管理 Homebrew formula。安装、升级、固定版本和卸载都会在执行前要求确认。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if store.brewAvailable {
                    Text("\(store.brewVersion) · 已安装 \(store.formulas.count) 个 formula · \(store.outdatedCount) 个可升级")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("formula 安装目录合计约 \(ByteCountFormatter.string(fromByteCount: store.totalInstalledSize, countStyle: .file))\(store.hasUnknownFormulaSizes ? " · 部分工具大小未知" : "")")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("按 Homebrew Cellar 中的已安装版本目录估算；依赖 formula 单独计入。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            HStack(spacing: 10) {
                TextField("搜索 formula，例如 node 或 ripgrep", text: $store.searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await store.search() } }
                    .accessibilityLabel("搜索 Homebrew formula")
                Button("搜索") { Task { await store.search() } }
                    .disabled(store.isBusy || !store.brewAvailable || store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            if store.isBusy && !store.hasLoaded {
                ProgressView("读取 Homebrew 清单…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !store.hasLoaded {
                ContentUnavailableView("尚未读取工具清单", systemImage: "terminal", description: Text("点击右上角“刷新工具清单”读取已安装的 Homebrew formula。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !store.brewAvailable {
                ContentUnavailableView("未找到 Homebrew", systemImage: "shippingbox", description: Text("支持标准安装位置 /opt/homebrew 和 /usr/local。安装 Homebrew 后刷新清单。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !store.searchResults.isEmpty {
                        Section("搜索结果 · \(store.searchResults.count)") {
                            ForEach(store.searchResults, id: \.self) { name in
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(name)
                                        Text(store.isInstalled(name) ? "已安装" : "Homebrew formula")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("安装") { pendingAction = .install(name) }
                                        .disabled(store.isBusy || store.isInstalled(name))
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    Section("已安装 formula · \(store.formulas.count)") {
                        if store.formulas.isEmpty {
                            Text("没有已安装的 Homebrew formula。")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(store.formulas) { formula in
                                HomebrewFormulaRow(formula: formula) { action in pendingAction = action }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }

            if let error = store.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .textSelection(.enabled)
            }
            if let message = store.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }
        }
        .navigationTitle("命令行工具")
        .confirmationDialog(pendingAction?.title ?? "确认 Homebrew 操作？", isPresented: Binding(
            get: { pendingAction != nil },
            set: { if !$0 { pendingAction = nil } }
        ), titleVisibility: .visible) {
            if let action = pendingAction {
                Button(action.buttonTitle, role: action.isDestructive ? .destructive : nil) {
                    pendingAction = nil
                    Task { await store.perform(action) }
                }
            }
            Button("取消", role: .cancel) { pendingAction = nil }
        } message: {
            Text(pendingAction?.confirmationMessage ?? "")
        }
    }
}

@MainActor
struct HomebrewFormulaRow: View {
    let formula: ManagedFormula
    let selectAction: (HomebrewAction) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.title3)
                .foregroundStyle(formula.isOutdated ? .orange : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(formula.name).font(.headline)
                    if formula.isOutdated {
                        Text("可升级")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.16), in: Capsule())
                    }
                    if formula.isPinned {
                        Text("已固定")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.blue.opacity(0.14), in: Capsule())
                    }
                }
                Text("已安装版本：\(formula.installedVersion)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("占用：\(formula.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "大小未知")")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Menu {
                if formula.isOutdated {
                    Button("升级…", systemImage: "arrow.up.circle") { selectAction(.upgrade(formula.name)) }
                }
                Button(formula.isPinned ? "解除固定…" : "固定当前版本…", systemImage: formula.isPinned ? "pin.slash" : "pin") {
                    selectAction(formula.isPinned ? .unpin(formula.name) : .pin(formula.name))
                }
                Divider()
                Button("卸载…", systemImage: "trash", role: .destructive) { selectAction(.uninstall(formula.name)) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(width: 30, height: 30)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("管理 \(formula.name)")
        }
        .padding(.vertical, 4)
    }
}
