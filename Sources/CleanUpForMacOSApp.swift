import SwiftUI
import Charts
import UniformTypeIdentifiers
import os

private let tooltipHoverLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "org.cleanupformacos.app",
    category: "TooltipHover"
)

private struct HoverInfoButton<Content: View>: View {
    let accessibilityLabel: String
    let logScope: String
    @ViewBuilder let content: () -> Content
    @State private var isTooltipPresented = false

    var body: some View {
        Button {} label: {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isTooltipPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            content()
                .frame(width: 360, alignment: .leading)
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
                }
        }
        .onHover { isHovering in
            isTooltipPresented = isHovering
            tooltipHoverLogger.info("Info icon hover: scope=\(logScope, privacy: .public), hovering=\(isHovering, privacy: .public)")
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct TooltipDetailRow: View {
    let label: String
    let value: String
    var isMonospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(isMonospaced ? .system(.caption, design: .monospaced) : .footnote)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

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
    @State private var expandedSubfolderRuleIDs: Set<String> = []

    init(store: CleanupStore) {
        _store = State(initialValue: store)
        _simulatorStore = State(initialValue: SimulatorManagerStore(cleanupStore: store))
    }

    private var categories: [String] {
        let ruleCategories = Set(availableRules.map { $0.rule.category })
            .subtracting(["全部", "模拟器管理", "清理记录", "配置管理"])
            .sorted()
        return ["全部", "模拟器管理"] + ruleCategories + ["清理记录", "配置管理"]
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

    private var lowRiskRules: [ConfiguredCleanupRule] {
        rulesSortedBySize(availableRules.filter { $0.rule.risk == .low })
    }

    private var mediumRiskRules: [ConfiguredCleanupRule] {
        rulesSortedBySize(availableRules.filter { $0.rule.risk == .medium })
    }

    private func rulesSortedBySize(_ rules: [ConfiguredCleanupRule]) -> [ConfiguredCleanupRule] {
        rules.sorted {
            let lhsSize = store.states[$0.id]?.size ?? -1
            let rhsSize = store.states[$1.id]?.size ?? -1
            if lhsSize != rhsSize { return lhsSize > rhsSize }
            return $0.rule.title.localizedStandardCompare($1.rule.title) == .orderedAscending
        }
    }

    var body: some View {
        NavigationSplitView {
            List(categories, id: \.self, selection: $selectedCategory) { category in
                Label(category, systemImage: category == "全部" ? "square.grid.2x2" : (category == "模拟器管理" ? "iphone.gen3" : (category == "清理记录" ? "clock.arrow.circlepath" : (category == "配置管理" ? "slider.horizontal.3" : "folder"))))
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
                } else if selectedCategory == "清理记录" {
                    CleanupHistoryView(store: store)
                } else {
                    VStack(spacing: 0) {
                        DiskSpaceOverviewView(current: store.currentDiskSpace, snapshots: store.diskSnapshots)
                        List {
                            if (selectedCategory ?? "全部") == "全部" {
                                if !lowRiskRules.isEmpty {
                                    Section("低风险") {
                                        ForEach(lowRiskRules) { cleanupRuleRow($0) }
                                    }
                                }
                                if !mediumRiskRules.isEmpty {
                                    Section("中风险") {
                                        ForEach(mediumRiskRules) { cleanupRuleRow($0) }
                                    }
                                }
                            } else {
                                ForEach(visibleRules) { cleanupRuleRow($0) }
                            }
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
                let isScanning = selectedCategory == "模拟器管理" ? simulatorStore.isBusy : store.isBusy
                let isConfiguration = selectedCategory == "配置管理"
                let isCleanupHistory = selectedCategory == "清理记录"
                Button {
                    if selectedCategory == "模拟器管理" {
                        Task { await simulatorStore.scan() }
                    } else if isConfiguration {
                        showingConfigurationImporter = true
                    } else if isCleanupHistory {
                        store.refreshCleanupLog()
                    } else {
                        refreshAndScanAllRules()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Group {
                            if isScanning && !isCleanupHistory && !isConfiguration {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: isConfiguration ? "square.and.arrow.down" : "arrow.clockwise")
                            }
                        }
                        .frame(width: 16, height: 16)
                        Text(isConfiguration ? "导入配置" : (isCleanupHistory ? "刷新记录" : (selectedCategory == "模拟器管理" ? "扫描模拟器" : "扫描全部缓存")))
                    }
                }
                .disabled((store.isBusy || simulatorStore.isBusy) && !isCleanupHistory)
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

    private func refreshAndScanAllRules() {
        guard store.reloadBundledConfiguration() else { return }
        let rulesToScan = availableRules
        Task { await store.scanAll(rules: rulesToScan) }
    }

    @ViewBuilder
    private func cleanupRuleRow(_ rule: ConfiguredCleanupRule) -> some View {
        CleanupRuleRow(
            configuredRule: rule,
            state: store.states[rule.id] ?? ScanState(),
            isSelected: store.isSelected(rule),
            subfoldersExpanded: expandedSubfolderRuleIDs.contains(rule.id),
            toggleSubfolders: { toggleSubfolders(for: rule.id) },
            toggleSelection: { store.toggleSelection(rule) },
            toggleSubfolderSelection: { store.toggleSubfolderSelection($0, in: rule) },
            isSubfolderSelected: { store.isSelected(rule, subfolderPath: $0) }
        )
        .id("\(rule.id)-expanded-\(expandedSubfolderRuleIDs.contains(rule.id))")
        .fixedSize(horizontal: false, vertical: true)
        .listRowSeparator(.visible)
    }

    private func toggleSubfolders(for ruleID: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if expandedSubfolderRuleIDs.contains(ruleID) {
                expandedSubfolderRuleIDs.remove(ruleID)
            } else {
                expandedSubfolderRuleIDs.insert(ruleID)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(store.statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Text("点击左侧“清理记录”查看操作历史")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct DiskSpaceOverviewView: View {
    private let cardHeight: CGFloat = 99

    let current: DiskSpaceSnapshot?
    let snapshots: [DiskSpaceSnapshot]

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            capacityCard
                .frame(width: 276)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("可用空间变化").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(snapshots.count) 次扫描").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                if snapshots.isEmpty {
                    VStack(spacing: 4) {
                        Label("暂无扫描记录", systemImage: "chart.xyaxis.line")
                            .font(.callout)
                        Text("手动扫描后会记录可用空间。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 60, maxHeight: 60)
                } else {
                    Chart(snapshots) { point in
                        LineMark(x: .value("时间", point.timestamp), y: .value("可用空间", point.availableBytes))
                            .foregroundStyle(.blue)
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                    .chartYAxis { AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let bytes = value.as(Int64.self) {
                                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                                        .font(.system(size: 8))
                            }
                        }
                    } }
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.system(size: 8))
                    } }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 64)
                    .animation(.easeInOut(duration: 0.75), value: snapshots.map(\.availableBytes))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .frame(height: cardHeight)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private var capacityCard: some View {
        HStack(spacing: 10) {
            ZStack {
                if let current, current.totalBytes > 0 {
                    Chart {
                        SectorMark(
                            angle: .value("已用", max(0, current.usedBytes)),
                            innerRadius: .ratio(0.72),
                            angularInset: 1.5
                        )
                        .foregroundStyle(Color.orange)
                        SectorMark(
                            angle: .value("可用", max(0, current.availableBytes)),
                            innerRadius: .ratio(0.72),
                            angularInset: 1.5
                        )
                        .foregroundStyle(Color.blue)
                    }
                    .chartLegend(.hidden)
                    .frame(width: 84, height: 84)
                    .animation(.easeInOut(duration: 0.75), value: current.usedBytes)
                    .overlay {
                        VStack(spacing: 1) {
                            Text(ByteCountFormatter.string(fromByteCount: current.totalBytes, countStyle: .file))
                                .font(.system(size: 8, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text("总空间").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        .frame(width: 94)
                    }
                } else {
                    ProgressView().frame(width: 84, height: 84)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                capacityLegend("已用", bytes: current?.usedBytes, color: .orange)
                capacityLegend("可用", bytes: current?.availableBytes, color: .blue)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: cardHeight, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func capacityLegend(_ title: String, bytes: Int64?, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
    }
}

private struct CleanupHistoryView: View {
    let store: CleanupStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("清理记录")
                        .font(.title2.weight(.semibold))
                    Text("操作历史仅保存在本机。记录可能包含本机路径。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(store.cleanupLogEntries.count) 条记录")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            if let error = store.cleanupLogError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            if store.cleanupLogEntries.isEmpty {
                ContentUnavailableView(
                    "还没有清理记录",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("完成一次清理或删除模拟器后，记录会显示在这里。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.cleanupLogEntries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.title)
                                .font(.headline)
                            Spacer(minLength: 12)
                            Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            Text(entry.action == "move_to_trash" ? "移到废纸篓" : (entry.action == "delete_simulator_device" ? "删除模拟器" : entry.action))
                            Text("·")
                            Text(ByteCountFormatter.string(fromByteCount: entry.scannedBytes, countStyle: .file))
                            Text("·")
                            Text(entry.result.hasPrefix("failed:") ? "失败" : "已完成")
                                .foregroundStyle(entry.result.hasPrefix("failed:") ? .red : .secondary)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Text(entry.contents)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        DisclosureGroup("详细信息") {
                            VStack(alignment: .leading, spacing: 8) {
                                TooltipDetailRow(label: "规则 ID", value: entry.ruleID, isMonospaced: true)
                                TooltipDetailRow(label: "操作结果", value: entry.result)
                                TooltipDetailRow(label: "配置版本", value: entry.configVersion)
                                TooltipDetailRow(label: "本机路径", value: entry.resolvedPath.isEmpty ? "—" : entry.resolvedPath, isMonospaced: true)
                            }
                            .padding(.vertical, 6)
                        }
                        .font(.footnote)
                    }
                    .padding(.vertical, 6)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("清理记录")
        .onAppear { store.refreshCleanupLog() }
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
        .confirmationDialog(store.selectedBootedCount > 0 ? "关闭并删除所选模拟器？" : "删除所选模拟器？", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button(store.selectedBootedCount > 0 ? "关闭并删除所选模拟器" : "删除所选模拟器", role: .destructive) {
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

private struct CleanupRuleRow: View {
    let configuredRule: ConfiguredCleanupRule
    private var rule: CleanupRule { configuredRule.rule }
    let state: ScanState
    let isSelected: Bool
    let subfoldersExpanded: Bool
    let toggleSubfolders: () -> Void
    let toggleSelection: () -> Void
    let toggleSubfolderSelection: (ScannedSubfolder) -> Void
    let isSubfolderSelected: (String) -> Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: state.size == nil ? "folder.badge.questionmark" : "folder.fill")
                .font(.title2)
                .foregroundStyle(rule.risk == .low ? .blue : .orange)
                .frame(width: 30)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(rule.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !state.subfolders.isEmpty {
                        Button(action: toggleSubfolders) {
                            HStack(spacing: 4) {
                                Image(systemName: subfoldersExpanded ? "chevron.down" : "chevron.right")
                                    .font(.caption.weight(.semibold))
                                Text("子文件夹（\(state.subfolders.count)）")
                                    .font(.callout)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(subfoldersExpanded ? "收起子文件夹" : "展开子文件夹")
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    HoverInfoButton(accessibilityLabel: "目录说明", logScope: "cleanup-rule") {
                        VStack(alignment: .leading, spacing: 11) {
                            Text(rule.title).font(.headline)
                            Text(rule.summary)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                            Divider()
                            TooltipDetailRow(label: "来自配置", value: configuredRule.profileName)
                            TooltipDetailRow(label: "删除影响", value: rule.impact)
                            TooltipDetailRow(label: "目录路径", value: rule.path, isMonospaced: true)
                        }
                    }
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
                if let error = state.error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }

                if subfoldersExpanded && !state.subfolders.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(state.subfolders) { subfolder in
                            ScannedSubfolderRow(
                                subfolder: subfolder,
                                toggleSelection: toggleSubfolderSelection,
                                isSelected: isSubfolderSelected
                            )
                        }
                    }
                    .padding(.leading, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            if state.size != nil {
                Label("扫描后可在底部选择清理", systemImage: "info.circle")
            }
        }
    }
}

private struct ScannedSubfolderRow: View {
    @State private var isExpanded = false

    let subfolder: ScannedSubfolder
    let toggleSelection: (ScannedSubfolder) -> Void
    let isSelected: (String) -> Bool

    private var descriptionText: String {
        subfolder.description ?? "此层级没有单独说明；大小包含其可见子文件夹。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 9) {
                if !subfolder.subfolders.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .frame(width: 16, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "收起 \(subfolder.name) 的子文件夹" : "展开 \(subfolder.name) 的子文件夹")
                } else {
                    Color.clear.frame(width: 16, height: 20)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(subfolder.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HoverInfoButton(accessibilityLabel: "子文件夹说明", logScope: "subfolder") {
                            VStack(alignment: .leading, spacing: 11) {
                                Text(subfolder.name).font(.headline)
                                Text(descriptionText)
                                    .font(.body)
                                    .fixedSize(horizontal: false, vertical: true)
                                Divider()
                                TooltipDetailRow(label: "相对路径", value: subfolder.relativePath, isMonospaced: true)
                                TooltipDetailRow(
                                    label: "目录大小",
                                    value: ByteCountFormatter.string(fromByteCount: subfolder.size, countStyle: .file)
                                )
                            }
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: subfolder.size, countStyle: .file))
                            .font(.system(.callout, design: .monospaced).weight(.semibold))
                    }
                }
                Button { toggleSelection(subfolder) } label: {
                    Label(isSelected(subfolder.relativePath) ? "已选择" : "选择清理", systemImage: isSelected(subfolder.relativePath) ? "checkmark.circle.fill" : "circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .disabled(subfolder.size == 0)
                .accessibilityLabel(isSelected(subfolder.relativePath) ? "取消选择子文件夹 \(subfolder.relativePath)" : "选择清理子文件夹 \(subfolder.relativePath)")
            }
            if isExpanded && !subfolder.subfolders.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(subfolder.subfolders) { child in
                        ScannedSubfolderRow(subfolder: child, toggleSelection: toggleSelection, isSelected: isSelected)
                    }
                }
                .padding(.leading, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
