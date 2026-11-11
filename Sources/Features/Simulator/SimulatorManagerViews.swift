import SwiftUI


@MainActor
struct SimulatorManagerView: View {
    @State private var store: SimulatorManagerStore
    @State private var showingDeleteConfirmation = false
    @State private var runtimeToDelete: ManagedSimulatorRuntime?

    init(store: SimulatorManagerStore) {
        _store = State(initialValue: store)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Xcode 模拟器空间")
                        .font(.title2.weight(.semibold))
                    Text("设备数据包含已安装 App、App 数据和设置。删除设备后，这些内容无法从本 App 恢复。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            if store.isBusy && !store.hasScanned {
                ProgressView("读取 Xcode 模拟器清单…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !store.hasScanned {
                ContentUnavailableView("尚未扫描模拟器", systemImage: "iphone.gen3", description: Text("扫描后会显示每台模拟器设备的数据和日志占用。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(store.devices) { device in
                            SimulatorDeviceRow(
                                device: device,
                                isSelected: store.isSelected(device),
                                toggleSelection: { store.toggleSelection(device) }
                            )
                        }
                    } header: {
                        HStack {
                            Text("设备 · \(store.devices.count)")
                            Spacer()
                            Text("占用估算：\(ByteCountFormatter.string(fromByteCount: store.totalDeviceBytes, countStyle: .file))")
                                .font(.footnote)
                        }
                    }

                    Section("共享运行时") {
                        ForEach(store.runtimes) { runtime in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(runtime.name)
                                    Text("构建 \(runtime.build) · \(runtime.state)")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                    if let reason = store.runtimeDeletionBlockReason(runtime) {
                                        Text(reason)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 6) {
                                    Text(ByteCountFormatter.string(fromByteCount: runtime.sizeBytes, countStyle: .file))
                                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                                    Button("删除运行时…", role: .destructive) {
                                        runtimeToDelete = runtime
                                        showingDeleteConfirmation = true
                                    }
                                    .disabled(store.isBusy || !store.canDeleteRuntime(runtime))
                                }
                            }
                        }
                        Text("删除通过 Xcode 的 simctl 运行时管理命令执行。仍有关联模拟器设备的运行时需先删除这些设备；移除后需要时可从 Xcode 重新下载。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
            }

            if store.selectedCount > 0 {
                HStack {
                    Text("已选择 \(store.selectedCount) 台 · \(ByteCountFormatter.string(fromByteCount: store.selectedBytes, countStyle: .file))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("删除所选模拟器…", role: .destructive) {
                        runtimeToDelete = nil
                        showingDeleteConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isBusy)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
        .navigationTitle("模拟器管理")
        .confirmationDialog(
            runtimeToDelete.map { "删除 \($0.name) 运行时？" } ?? (store.selectedBootedCount > 0 ? "关闭并删除所选模拟器？" : "删除所选模拟器？"),
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            if let runtime = runtimeToDelete {
                Button("删除运行时", role: .destructive) {
                    Task {
                        await store.deleteRuntime(runtime)
                        runtimeToDelete = nil
                    }
                }
            } else {
                Button(store.selectedBootedCount > 0 ? "关闭并删除所选模拟器" : "删除所选模拟器", role: .destructive) {
                    Task { await store.deleteSelected() }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(runtimeToDelete.map(store.runtimeDeletionConfirmationText) ?? store.deletionConfirmationText)
        }
        .alert("模拟器管理结果", isPresented: Binding(
            get: { store.message != nil },
            set: { if !$0 { store.message = nil } }
        )) {
            Button("好", role: .cancel) { store.message = nil }
        } message: {
            Text(store.message ?? "")
        }
    }
}

@MainActor
struct TemporaryBuildManagerView: View {
    @State private var store: TemporaryBuildManagerStore
    @State private var showingTrashConfirmation = false
    @State private var expandedProjectNames: Set<String> = []

    init(store: TemporaryBuildManagerStore) {
        _store = State(initialValue: store)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("临时构建产物")
                    .font(.title2.weight(.semibold))
                Text("按编译文件和目录名识别 /private/tmp 中的项目构建目录。请逐项检查；移入废纸篓后，构建结果需要重新生成。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Label("只显示当前账户拥有、包含大量编译产物且没有符号链接的目录。发布、审核和归档目录会跳过。项目可展开，也可在项目标题处全选。", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            if store.isBusy && !store.hasScanned {
                ProgressView("检查临时构建目录…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !store.hasScanned {
                ContentUnavailableView("尚未扫描临时构建", systemImage: "hammer", description: Text("扫描后会按项目归组显示可检查的临时构建目录。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.artifacts.isEmpty {
                ContentUnavailableView("没有发现候选目录", systemImage: "checkmark.circle", description: Text("没有找到符合当前编译产物条件的临时目录。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.projectNames, id: \.self) { projectName in
                        let artifacts = store.artifacts(for: projectName)
                        Section {
                            DisclosureGroup(
                                isExpanded: Binding(
                                    get: { expandedProjectNames.contains(projectName) },
                                    set: { isExpanded in
                                        if isExpanded {
                                            expandedProjectNames.insert(projectName)
                                        } else {
                                            expandedProjectNames.remove(projectName)
                                        }
                                    }
                                )
                            ) {
                                ForEach(artifacts) { artifact in
                                    HStack(spacing: 12) {
                                        Button { store.toggleSelection(artifact) } label: {
                                            Image(systemName: store.isSelected(artifact) ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(store.isSelected(artifact) ? Color.accentColor : Color.secondary)
                                                .font(.title3)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(store.isSelected(artifact) ? "取消选择 \(artifact.directoryName)" : "选择 \(artifact.directoryName)")

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(artifact.directoryName)
                                                .font(.callout.weight(.medium))
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Text("\(artifact.compilerFileCount.formatted()) 个编译文件 · 最近修改 \(artifact.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(ByteCountFormatter.string(fromByteCount: artifact.size, countStyle: .file))
                                            .font(.system(.callout, design: .monospaced).weight(.semibold))
                                    }
                                    .padding(.vertical, 3)
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Button { store.toggleProjectSelection(projectName) } label: {
                                        let isFullySelected = store.isProjectFullySelected(projectName)
                                        let hasSelection = store.projectHasSelection(projectName)
                                        Image(systemName: isFullySelected ? "checkmark.circle.fill" : (hasSelection ? "minus.circle.fill" : "circle"))
                                            .foregroundStyle(hasSelection ? Color.accentColor : Color.secondary)
                                            .font(.title3)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(store.isProjectFullySelected(projectName) ? "取消选择项目 \(projectName)" : "全选项目 \(projectName)")

                                    Text(projectName)
                                        .font(.headline)
                                    Spacer()
                                    Text("\(artifacts.count) 个目录 · \(ByteCountFormatter.string(fromByteCount: artifacts.reduce(0) { $0 + $1.size }, countStyle: .file))")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }

            if let error = store.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }

            if store.selectedCount > 0 {
                HStack {
                    Text("已选择 \(store.selectedCount) 个目录 · \(ByteCountFormatter.string(fromByteCount: store.selectedBytes, countStyle: .file))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("移到废纸篓…", role: .destructive) {
                        showingTrashConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isBusy)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
        .navigationTitle("临时构建")
        .sheet(isPresented: $showingTrashConfirmation) {
            CleanupConfirmationSheet(items: store.cleanupConfirmationItems, summary: store.confirmationText,
                isBusy: store.isBusy,
                cancel: { showingTrashConfirmation = false },
                confirm: {
                    showingTrashConfirmation = false
                    Task { await store.trashSelected() }
                })
        }
        .alert("临时构建清理结果", isPresented: Binding(
            get: { store.message != nil },
            set: { if !$0 { store.message = nil } }
        )) {
            Button("好", role: .cancel) { store.message = nil }
        } message: {
            Text(store.message ?? "")
        }
    }
}

@MainActor
struct SimulatorDeviceRow: View {
    let device: ManagedSimulatorDevice
    let isSelected: Bool
    let toggleSelection: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.gen3")
                .font(.title2)
                .foregroundStyle(device.isBooted ? .green : .secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(device.name).font(.headline)
                    Text(device.isBooted ? "正在运行 · 删除前将关机" : (device.isAvailable ? "已关机" : "不可用"))
                        .font(.caption)
                        .foregroundStyle(device.isBooted ? .green : .secondary)
                }
                Text("\(device.deviceTypeName) · \(device.runtimeName)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("设备数据 \(ByteCountFormatter.string(fromByteCount: device.dataBytes, countStyle: .file)) · 日志 \(ByteCountFormatter.string(fromByteCount: device.logBytes, countStyle: .file))")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            Text(ByteCountFormatter.string(fromByteCount: device.totalBytes, countStyle: .file))
                .font(.system(.body, design: .monospaced).weight(.semibold))
            Button(action: toggleSelection) {
                Label(isSelected ? "已选择" : "选择删除", systemImage: isSelected ? "checkmark.circle.fill" : "circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .disabled(!device.canDelete)
            .accessibilityLabel(isSelected ? "取消选择 \(device.name)" : "选择删除 \(device.name)")
        }
        .padding(.vertical, 5)
    }
}
