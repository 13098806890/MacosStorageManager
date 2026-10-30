import SwiftUI
import Charts
import UniformTypeIdentifiers

private struct CleanupConfigurationDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let configuration: CleanupConfiguration

    init(configuration: CleanupConfiguration) {
        self.configuration = configuration
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.configuration = try JSONDecoder().decode(CleanupConfiguration.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(self.configuration))
    }
}

@main
struct CleanUpForMacOSApp: App {
    @State private var store = CleanupStore()

    var body: some Scene {
        WindowGroup {
            CleanupHomeView(store: store)
                .frame(minWidth: 760, minHeight: 540)
        }
        .windowResizability(.contentSize)
    }
}

private struct CleanupHomeView: View {
    @State private var store: CleanupStore
    @State private var simulatorStore: SimulatorManagerStore
    @State private var selectedCategory: String? = "全部"
    @State private var showingCleanupConfirmation = false
    @State private var showingConfigurationImporter = false

    init(store: CleanupStore) {
        _store = State(initialValue: store)
        _simulatorStore = State(initialValue: SimulatorManagerStore(cleanupStore: store))
    }

    private var categories: [String] {
        ["全部", "模拟器管理", "配置管理"] + Array(Set(availableRules.map { $0.rule.category })).filter { $0 != "模拟器管理" }.sorted()
    }

    private var availableRules: [ConfiguredCleanupRule] {
        store.rules.filter { configuredRule in
            guard let path = configuredRule.rule.resolvedPath?.path else { return false }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    private var visibleRules: [ConfiguredCleanupRule] {
        (selectedCategory ?? "全部") == "全部" ? availableRules : availableRules.filter { $0.rule.category == selectedCategory }
    }

    var body: some View {
        NavigationSplitView {
            List(categories, id: \.self, selection: $selectedCategory) { category in
                Label(category, systemImage: category == "全部" ? "square.grid.2x2" : (category == "模拟器管理" ? "iphone.gen3" : (category == "配置管理" ? "slider.horizontal.3" : "folder")))
                    .tag(category)
            }
            .navigationTitle("清理项目")
            .listStyle(.sidebar)
        } detail: {
            Group {
                if selectedCategory == "模拟器管理" {
                    VStack(spacing: 0) {
                        DiskSpaceOverviewView(current: store.currentDiskSpace, snapshots: store.diskSnapshots)
                        SimulatorManagerView(store: simulatorStore)
                    }
                } else if selectedCategory == "配置管理" {
                    VStack(spacing: 0) {
                        DiskSpaceOverviewView(current: store.currentDiskSpace, snapshots: store.diskSnapshots)
                        ConfigurationManagerView(store: store, importConfigurations: { showingConfigurationImporter = true })
                    }
                } else {
                    VStack(spacing: 0) {
                        header
                        DiskSpaceOverviewView(current: store.currentDiskSpace, snapshots: store.diskSnapshots)
                        List(visibleRules) { rule in
                            CleanupRuleRow(
                                configuredRule: rule,
                                state: store.states[rule.id] ?? ScanState(),
                                isSelected: store.isSelected(rule),
                                toggleSelection: { store.toggleSelection(rule) },
                                toggleSubfolderSelection: { store.toggleSubfolderSelection($0, in: rule) },
                                isSubfolderSelected: { store.isSelected(rule, subfolderName: $0) }
                            ) {
                                Task { await store.scan(rule) }
                            }
                            .listRowSeparator(.visible)
                        }
                        .listStyle(.inset)
                        footer
                    }
                    .navigationTitle("清理扫描")
                }
            }
        }
        .alert("确认移到废纸篓？", isPresented: $showingCleanupConfirmation) {
            Button("取消", role: .cancel) {}
            Button("移到废纸篓", role: .destructive) {
                Task { await store.cleanScannedRules() }
            }
        } message: {
            Text(store.cleanupConfirmationText)
        }
        .alert("操作结果", isPresented: Binding(
            get: { store.message != nil },
            set: { if !$0 { store.message = nil } }
        )) {
            Button("好", role: .cancel) { store.message = nil }
        } message: {
            Text(store.message ?? "")
        }
        .fileImporter(isPresented: $showingConfigurationImporter, allowedContentTypes: [.json], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls): store.importConfigurations(from: urls)
            case let .failure(error): store.message = "配置导入失败：\(error.localizedDescription)"
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if selectedCategory == "模拟器管理" {
                        Task { await simulatorStore.scan() }
                    } else if selectedCategory == "配置管理" {
                        showingConfigurationImporter = true
                    } else {
                        Task { await store.scanAll(rules: visibleRules) }
                    }
                } label: {
                    Label(selectedCategory == "模拟器管理" ? "扫描模拟器" : (selectedCategory == "配置管理" ? "导入配置" : "扫描"), systemImage: selectedCategory == "配置管理" ? "square.and.arrow.down" : "arrow.clockwise")
                }
                .disabled(store.isBusy || simulatorStore.isBusy)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if store.scannedSelectionCount > 0 {
                HStack {
                    Text("已选择 \(store.scannedSelectionCount) 项 · \(store.selectedSizeDescription)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("清理所选项目…", role: .destructive) {
                        showingCleanupConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("扫描后由你选择要清理的内容。")
                    .font(.title2.weight(.semibold))
                Text("路径来自可公开分享的脱敏配置；清理默认移到废纸篓。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button {
                Task { await store.scanAll(rules: visibleRules) }
            } label: {
                Label("扫描已启用规则", systemImage: "arrow.clockwise")
            }
            .disabled(store.isBusy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Text(store.statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button("查看清理记录") { store.showLatestLog() }
                .buttonStyle(.link)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct DiskSpaceOverviewView: View {
    private let cardHeight: CGFloat = 184

    let current: DiskSpaceSnapshot?
    let snapshots: [DiskSpaceSnapshot]

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            capacityCard
                .frame(width: 190)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("可用空间变化").font(.headline)
                    Spacer()
                    Text("\(snapshots.count) 次扫描").font(.caption).foregroundStyle(.secondary)
                }
                if snapshots.isEmpty {
                    ContentUnavailableView("暂无扫描记录", systemImage: "chart.xyaxis.line", description: Text("手动扫描后会记录可用空间。"))
                        .frame(maxWidth: .infinity, minHeight: 112)
                } else {
                    Chart(snapshots) { point in
                        LineMark(x: .value("时间", point.timestamp), y: .value("可用空间", point.availableBytes))
                            .foregroundStyle(.blue)
                            .interpolationMethod(.catmullRom)
                        PointMark(x: .value("时间", point.timestamp), y: .value("可用空间", point.availableBytes))
                            .foregroundStyle(.blue)
                    }
                    .chartYAxis { AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let bytes = value.as(Int64.self) {
                                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                            }
                        }
                    } }
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day().hour().minute())
                    } }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 126)
                    .animation(.easeInOut(duration: 0.75), value: snapshots.map(\.availableBytes))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .frame(height: cardHeight)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var capacityCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("磁盘空间").font(.headline)
            HStack(spacing: 10) {
                ZStack {
                    if let current, current.totalBytes > 0 {
                        Chart {
                            SectorMark(
                                angle: .value("已用", max(0, current.usedBytes)),
                                innerRadius: .ratio(0.72),
                                angularInset: 1.5
                            )
                            .foregroundStyle(Color.red)
                            SectorMark(
                                angle: .value("可用", max(0, current.availableBytes)),
                                innerRadius: .ratio(0.72),
                                angularInset: 1.5
                            )
                            .foregroundStyle(Color.blue)
                        }
                        .chartLegend(.hidden)
                        .frame(width: 82, height: 82)
                        .animation(.easeInOut(duration: 0.75), value: current.usedBytes)
                        .overlay {
                            VStack(spacing: 1) {
                                Text(ByteCountFormatter.string(fromByteCount: current.totalBytes, countStyle: .file))
                                    .font(.system(.caption, design: .rounded).weight(.semibold))
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                Text("总空间").font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            .frame(width: 62)
                        }
                    } else {
                        ProgressView().frame(width: 82, height: 82)
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    capacityLegend("已用", bytes: current?.usedBytes, color: .red)
                    capacityLegend("可用", bytes: current?.availableBytes, color: .blue)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: cardHeight, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func capacityLegend(_ title: String, bytes: Int64?, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
                Text(bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
    }
}

private struct ConfigurationManagerView: View {
    let store: CleanupStore
    let importConfigurations: () -> Void
    @State private var showingExporter = false
    @State private var exportDocument: CleanupConfigurationDocument?
    @State private var exportFilename = "cleanup-rules"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("配置文件管理").font(.title2.weight(.semibold))
                    Text("你的个人配置保存在 Config/cleanup-rules.json；以后新增路径放在这里。也可以导入其他 JSON 配置，或导出配置备份。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: importConfigurations) {
                    Label("导入 JSON 配置", systemImage: "square.and.arrow.down")
                }.buttonStyle(.borderedProminent)
            }
            .padding(20)

            List {
                ForEach(store.profiles) { profile in
                    Section {
                        ForEach(profile.rules) { rule in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(rule.title).font(.headline)
                                    Text(rule.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                    Text("\(rule.category) · \(rule.path)").font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                                }
                                Spacer(minLength: 12)
                                Toggle("加入扫描", isOn: Binding(
                                    get: { profile.enabledRuleIDs.contains(rule.id) },
                                    set: { store.setRuleEnabled($0, ruleID: rule.id, profileID: profile.id) }
                                ))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .accessibilityLabel("将规则加入扫描列表：\(rule.title)")
                            }
                            .padding(.vertical, 3)
                        }
                    } header: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.isBundled ? "我的配置（\(profile.role)）" : profile.name).font(.headline)
                                Text("角色：\(profile.role) · 版本：\(profile.configVersion) · \(profile.rules.count) 条规则")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                exportDocument = CleanupConfigurationDocument(configuration: profile.configuration)
                                exportFilename = profile.isBundled ? "cleanup-rules" : profile.name
                                showingExporter = true
                            } label: {
                                Label("导出", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.borderless)
                            .help("导出此配置文件")
                            if !profile.isBundled {
                                Button(role: .destructive) { store.removeProfile(profile.id) } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("移除配置")
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .navigationTitle("配置管理")
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFilename
        ) { result in
            switch result {
            case .success:
                store.message = "配置文件已导出。"
            case let .failure(error):
                store.message = "配置文件导出失败：\(error.localizedDescription)"
            }
            exportDocument = nil
        }
    }
}

private struct SimulatorManagerView: View {
    @State private var store: SimulatorManagerStore
    @State private var showingDeleteConfirmation = false

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
                Spacer(minLength: 8)
                Button {
                    Task { await store.scan() }
                } label: {
                    Label("扫描模拟器", systemImage: "arrow.clockwise")
                }
                .disabled(store.isBusy)
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
                                    Text(runtime.isAvailable ? "已安装 · 多台模拟器共用" : "当前不可用")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("由 Xcode 管理")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("运行时占用和移除操作请在 Xcode > Settings > Components 查看。Xcode 会显示可回收空间。")
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
        .confirmationDialog("删除所选模拟器？", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("删除所选模拟器", role: .destructive) {
                Task { await store.deleteSelected() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(store.deletionConfirmationText)
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

private struct SimulatorDeviceRow: View {
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
                    Text(device.isBooted ? "正在运行" : (device.isAvailable ? "已关机" : "不可用"))
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

private struct CleanupRuleRow: View {
    @State private var subfoldersExpanded = false

    let configuredRule: ConfiguredCleanupRule
    private var rule: CleanupRule { configuredRule.rule }
    let state: ScanState
    let isSelected: Bool
    let toggleSelection: () -> Void
    let toggleSubfolderSelection: (ScannedSubfolder) -> Void
    let isSubfolderSelected: (String) -> Bool
    let scan: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: state.size == nil ? "folder.badge.questionmark" : "folder.fill")
                .font(.title2)
                .foregroundStyle(rule.risk == .low ? .blue : .orange)
                .frame(width: 30)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(rule.title).font(.headline)
                    Text(rule.risk.label)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(rule.risk == .low ? Color.green.opacity(0.14) : Color.orange.opacity(0.16), in: Capsule())
                    Spacer()
                    if state.size != nil {
                        Button(action: toggleSelection) {
                            Label(isSelected ? "已选择" : "选择清理", systemImage: isSelected ? "checkmark.circle.fill" : "circle")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isSelected ? "取消选择 \(rule.title)" : "选择清理 \(rule.title)")
                    }
                    if let size = state.size {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                    }
                }
                Text(rule.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("来自配置：\(configuredRule.profileName)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("删除影响：\(rule.impact)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(rule.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if state.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(state.size == nil ? "扫描" : "重新扫描", action: scan)
                            .buttonStyle(.borderless)
                    }
                }
                if let error = state.error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                if !state.subfolders.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            subfoldersExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: subfoldersExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold))
                            Text("子文件夹（\(state.subfolders.count)）")
                                .font(.callout)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(subfoldersExpanded ? "收起子文件夹" : "展开子文件夹")
                    .padding(.top, 4)

                    if subfoldersExpanded {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(state.subfolders) { subfolder in
                                HStack(alignment: .top, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(subfolder.name)
                                                .font(.callout.weight(.medium))
                                            Spacer()
                                            Text(ByteCountFormatter.string(fromByteCount: subfolder.size, countStyle: .file))
                                                .font(.system(.callout, design: .monospaced).weight(.semibold))
                                        }
                                        Text(subfolder.description ?? "暂无说明；可在配置的 subfolderDescriptions 中添加。")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    Button {
                                        toggleSubfolderSelection(subfolder)
                                    } label: {
                                        Label(isSubfolderSelected(subfolder.name) ? "已选择" : "选择清理", systemImage: isSubfolderSelected(subfolder.name) ? "checkmark.circle.fill" : "circle")
                                            .labelStyle(.iconOnly)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(subfolder.size == 0)
                                    .accessibilityLabel(isSubfolderSelected(subfolder.name) ? "取消选择子文件夹 \(subfolder.name)" : "选择清理子文件夹 \(subfolder.name)")
                                }
                            }
                        }
                        .padding(.leading, 12)
                        .padding(.vertical, 6)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            if state.size != nil {
                Label("扫描后可在底部选择清理", systemImage: "info.circle")
            }
        }
    }
}
