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
                .frame(minWidth: 1040, minHeight: 700)
        }
        .defaultSize(width: 1200, height: 820)
        .windowResizability(.contentSize)
    }
}

private struct CleanupHomeView: View {
    @State private var store: CleanupStore
    @State private var simulatorStore: SimulatorManagerStore
    @State private var temporaryBuildStore: TemporaryBuildManagerStore
    @State private var homebrewStore = HomebrewManagerStore()
    @State private var selectedCategory: String? = "全部"
    @State private var isFullScanInProgress = false
    @State private var showingCleanupConfirmation = false
    @State private var showingConfigurationImporter = false
    @State private var expandedSubfolderRuleIDs: Set<String> = []
    @State private var expandedOverviewProjectNames: Set<String> = []

    init(store: CleanupStore) {
        _store = State(initialValue: store)
        _simulatorStore = State(initialValue: SimulatorManagerStore(cleanupStore: store))
        _temporaryBuildStore = State(initialValue: TemporaryBuildManagerStore(cleanupStore: store))
    }

    private var categories: [String] {
        let ruleCategories = Set(availableRules.map { $0.rule.category })
            .subtracting(["全部", "模拟器管理", "临时构建", "命令行工具", "清理记录", "配置管理"])
            .sorted()
        return ["全部"] + ruleCategories + ["模拟器管理", "临时构建", "命令行工具", "清理记录", "配置管理"]
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

    private var visibleLowRiskRules: [ConfiguredCleanupRule] {
        rulesSortedBySize(visibleRules.filter { $0.rule.risk == .low })
    }

    private var visibleMediumRiskRules: [ConfiguredCleanupRule] {
        rulesSortedBySize(visibleRules.filter { $0.rule.risk == .medium })
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
                HStack(spacing: 8) {
                    Label(category, systemImage: categorySymbol(for: category))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if isCategoryScanning(category) {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityLabel("正在扫描\(category)")
                    } else if let size = sidebarSize(for: category) {
                        let formattedSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                        Text((homebrewStore.hasUnknownFormulaSizes && (category == "全部" || category == "命令行工具") ? "≥" : "") + formattedSize)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .accessibilityLabel("扫描占用 \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                    }
                }
                    .tag(category)
            }
            .navigationTitle("清理项目")
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            Group {
                if selectedCategory == "模拟器管理" {
                    VStack(spacing: 0) {
                        DiskSpaceOverviewView(current: store.currentDiskSpace, snapshots: store.diskSnapshots)
                        SimulatorManagerView(store: simulatorStore)
                    }
                } else if selectedCategory == "临时构建" {
                    VStack(spacing: 0) {
                        DiskSpaceOverviewView(current: store.currentDiskSpace, snapshots: store.diskSnapshots)
                        TemporaryBuildManagerView(store: temporaryBuildStore)
                    }
                } else if selectedCategory == "命令行工具" {
                    HomebrewManagerView(store: homebrewStore)
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
                                overviewSummarySection
                                simulatorOverviewSection
                                temporaryBuildOverviewSection
                                homebrewOverviewSection
                            } else {
                                if !visibleLowRiskRules.isEmpty {
                                    Section("低风险缓存 · \(visibleLowRiskRules.count) 项 · \(ruleGroupSizeLabel(visibleLowRiskRules))") {
                                        ForEach(visibleLowRiskRules) { cleanupRuleRow($0) }
                                    }
                                }
                                if !visibleMediumRiskRules.isEmpty {
                                    Section("中风险缓存 · \(visibleMediumRiskRules.count) 项 · \(ruleGroupSizeLabel(visibleMediumRiskRules))") {
                                        ForEach(visibleMediumRiskRules) { cleanupRuleRow($0) }
                                    }
                                }
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
                let isScanning = isFullScanInProgress || (selectedCategory == "模拟器管理" ? simulatorStore.isBusy : (selectedCategory == "临时构建" ? temporaryBuildStore.isBusy : (selectedCategory == "命令行工具" ? homebrewStore.isBusy : store.isBusy)))
                let isConfiguration = selectedCategory == "配置管理"
                let isCleanupHistory = selectedCategory == "清理记录"
                Button {
                    if selectedCategory == "模拟器管理" {
                        Task { await simulatorStore.scan() }
                    } else if selectedCategory == "临时构建" {
                        Task { await temporaryBuildStore.scan() }
                    } else if selectedCategory == "命令行工具" {
                        Task { await homebrewStore.refresh() }
                    } else if isConfiguration {
                        showingConfigurationImporter = true
                    } else if isCleanupHistory {
                        store.refreshCleanupLog()
                    } else if selectedCategory == "全部" {
                        scanAllTabs()
                    } else {
                        refreshAndScanSelectedRuleCategory()
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
                        Text(isConfiguration ? "导入配置" : (isCleanupHistory ? "刷新记录" : (selectedCategory == "模拟器管理" ? "扫描模拟器" : (selectedCategory == "临时构建" ? "扫描临时构建" : (selectedCategory == "命令行工具" ? "刷新工具清单" : (selectedCategory == "全部" ? "扫描全部" : "扫描\(selectedCategory ?? "缓存")"))))))
                    }
                }
                .disabled((isFullScanInProgress || store.isBusy || simulatorStore.isBusy || temporaryBuildStore.isBusy || homebrewStore.isBusy) && !isCleanupHistory)
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

    private func refreshAndScanSelectedRuleCategory() {
        guard store.reloadBundledConfiguration() else { return }
        guard let category = selectedCategory else { return }
        let rulesToScan = availableRules.filter { $0.rule.category == category }
        Task { await store.scanAll(rules: rulesToScan) }
    }

    private func scanAllTabs() {
        guard !isFullScanInProgress, store.reloadBundledConfiguration() else { return }
        let rulesToScan = availableRules
        isFullScanInProgress = true
        Task {
            await store.scanAll(rules: rulesToScan)
            await simulatorStore.scan()
            await temporaryBuildStore.scan()
            await homebrewStore.refresh()
            store.refreshCleanupLog()
            isFullScanInProgress = false
        }
    }

    private func categorySymbol(for category: String) -> String {
        switch category {
        case "全部": "square.grid.2x2"
        case "模拟器管理": "iphone.gen3"
        case "临时构建": "hammer"
        case "命令行工具": "terminal"
        case "清理记录": "clock.arrow.circlepath"
        case "配置管理": "slider.horizontal.3"
        default: "folder"
        }
    }

    private func isCategoryScanning(_ category: String) -> Bool {
        if isFullScanInProgress { return true }
        switch category {
        case "全部": return isFullScanInProgress
        case "模拟器管理": return simulatorStore.isBusy
        case "临时构建": return temporaryBuildStore.isBusy
        case "命令行工具": return homebrewStore.isBusy
        case "清理记录", "配置管理": return false
        default: return availableRules.filter { $0.rule.category == category }.contains { store.states[$0.id]?.isScanning == true }
        }
    }

    private func sidebarSize(for category: String) -> Int64? {
        switch category {
        case "全部":
            guard !isFullScanInProgress,
                  simulatorStore.hasScanned,
                  simulatorStore.errorMessage == nil,
                  temporaryBuildStore.hasScanned,
                  temporaryBuildStore.errorMessage == nil,
                  homebrewStore.hasLoaded,
                  homebrewStore.errorMessage == nil,
                  rulesHaveFinishedScanning(availableRules) else { return nil }
            return scannedRuleBytes(availableRules) + simulatorStore.totalScannedBytes + temporaryBuildStore.totalBytes + homebrewStore.totalInstalledSize
        case "模拟器管理":
            return simulatorStore.hasScanned && simulatorStore.errorMessage == nil ? simulatorStore.totalScannedBytes : nil
        case "临时构建":
            return temporaryBuildStore.hasScanned && temporaryBuildStore.errorMessage == nil ? temporaryBuildStore.totalBytes : nil
        case "命令行工具":
            return homebrewStore.hasLoaded && homebrewStore.errorMessage == nil ? homebrewStore.totalInstalledSize : nil
        case "清理记录", "配置管理":
            return nil
        default:
            let categoryRules = availableRules.filter { $0.rule.category == category }
            guard !categoryRules.isEmpty, rulesHaveFinishedScanning(categoryRules) else { return nil }
            return scannedRuleBytes(categoryRules)
        }
    }

    private func rulesHaveFinishedScanning(_ rules: [ConfiguredCleanupRule]) -> Bool {
        rules.allSatisfy { rule in
            guard let state = store.states[rule.id] else { return false }
            return state.size != nil && state.error == nil
        }
    }

    private func scannedRuleBytes(_ rules: [ConfiguredCleanupRule]) -> Int64 {
        rules.reduce(0) { $0 + (store.states[$1.id]?.size ?? 0) }
    }

    @ViewBuilder
    private var overviewSummarySection: some View {
        Section("空间扫描总览") {
            if isFullScanInProgress {
                Label("正在扫描所有项目分类…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            } else if let total = sidebarSize(for: "全部") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已扫描项目占用约 \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                        .font(.headline)
                    Text("合计包含缓存、模拟器、临时构建和 Homebrew 工具目录的估算占用。各类项目的清理方式不同。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("点击右上角“扫描全部”读取各分类的占用。扫描失败或尚未扫描的分类不会计入总量。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func ruleGroupSizeLabel(_ rules: [ConfiguredCleanupRule]) -> String {
        guard rulesHaveFinishedScanning(rules) else { return "尚未完成扫描" }
        return ByteCountFormatter.string(fromByteCount: scannedRuleBytes(rules), countStyle: .file)
    }

    @ViewBuilder
    private var simulatorOverviewSection: some View {
        Section {
            if !simulatorStore.hasScanned {
                Text("尚未扫描模拟器。")
                    .foregroundStyle(.secondary)
            } else {
                if let error = simulatorStore.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                if simulatorStore.devices.isEmpty && simulatorStore.runtimes.isEmpty {
                    Text("没有发现模拟器设备或运行时。")
                        .foregroundStyle(.secondary)
                }
                if !simulatorStore.devices.isEmpty {
                    Text("设备 · \(simulatorStore.devices.count)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(simulatorStore.devices) { device in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.name)
                                    .font(.callout.weight(.medium))
                                Text("\(device.runtimeName) · \(device.state)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: device.totalBytes, countStyle: .file))
                                .font(.system(.callout, design: .monospaced).weight(.medium))
                        }
                    }
                }
                if !simulatorStore.runtimes.isEmpty {
                    Text("共享运行时 · \(simulatorStore.runtimes.count)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(simulatorStore.runtimes) { runtime in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(runtime.name)
                                    .font(.callout.weight(.medium))
                                Text("构建 \(runtime.build) · \(runtime.state)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: runtime.sizeBytes, countStyle: .file))
                                .font(.system(.callout, design: .monospaced).weight(.medium))
                        }
                    }
                }
            }
        } header: {
            overviewSectionHeader(
                "模拟器与运行时",
                summary: simulatorStore.hasScanned && simulatorStore.errorMessage == nil
                    ? "\(simulatorStore.devices.count) 台设备 · \(simulatorStore.runtimes.count) 个运行时 · \(ByteCountFormatter.string(fromByteCount: simulatorStore.totalScannedBytes, countStyle: .file))"
                    : nil,
                destination: "模拟器管理"
            )
        }
    }

    @ViewBuilder
    private var temporaryBuildOverviewSection: some View {
        Section {
            if !temporaryBuildStore.hasScanned {
                Text("尚未扫描临时构建目录。")
                    .foregroundStyle(.secondary)
            } else if let error = temporaryBuildStore.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if temporaryBuildStore.artifacts.isEmpty {
                Text("没有发现符合条件的临时构建目录。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(temporaryBuildStore.projectNames, id: \.self) { projectName in
                    let artifacts = temporaryBuildStore.artifacts(for: projectName)
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { expandedOverviewProjectNames.contains(projectName) },
                            set: { isExpanded in
                                if isExpanded {
                                    expandedOverviewProjectNames.insert(projectName)
                                } else {
                                    expandedOverviewProjectNames.remove(projectName)
                                }
                            }
                        )
                    ) {
                        ForEach(artifacts) { artifact in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(artifact.directoryName)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text("\(artifact.compilerFileCount.formatted()) 个编译文件 · 最近修改 \(artifact.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: artifact.size, countStyle: .file))
                                    .font(.system(.callout, design: .monospaced).weight(.medium))
                            }
                        }
                    } label: {
                        HStack {
                            Text(projectName)
                                .font(.callout.weight(.medium))
                            Spacer()
                            Text("\(artifacts.count) 个目录 · \(ByteCountFormatter.string(fromByteCount: artifacts.reduce(0) { $0 + $1.size }, countStyle: .file))")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            overviewSectionHeader(
                "临时构建",
                summary: temporaryBuildStore.hasScanned && temporaryBuildStore.errorMessage == nil
                    ? "\(temporaryBuildStore.artifacts.count) 个目录 · \(ByteCountFormatter.string(fromByteCount: temporaryBuildStore.totalBytes, countStyle: .file))"
                    : nil,
                destination: "临时构建"
            )
        }
    }

    @ViewBuilder
    private var homebrewOverviewSection: some View {
        Section {
            if !homebrewStore.hasLoaded {
                Text("尚未读取 Homebrew 工具清单。")
                    .foregroundStyle(.secondary)
            } else if let error = homebrewStore.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if !homebrewStore.brewAvailable {
                Text("未找到 Homebrew。")
                    .foregroundStyle(.secondary)
            } else if homebrewStore.formulas.isEmpty {
                Text("没有已安装的 Homebrew formula。")
                    .foregroundStyle(.secondary)
            } else {
                DisclosureGroup {
                    ForEach(homebrewFormulasBySize) { formula in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(formula.name)
                                    .font(.callout.weight(.medium))
                                Text("已安装版本：\(formula.installedVersion)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(formula.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "大小未知")
                                .font(.system(.callout, design: .monospaced).weight(.medium))
                        }
                    }
                } label: {
                    HStack {
                        Text("显示已安装工具")
                        Spacer()
                        Text("\(homebrewStore.formulas.count) 个 formula · \(homebrewStore.hasUnknownFormulaSizes ? "≥" : "")\(ByteCountFormatter.string(fromByteCount: homebrewStore.totalInstalledSize, countStyle: .file))")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text("这里显示的是已安装工具占用。卸载请到管理页操作，可能影响依赖这些工具的项目。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            overviewSectionHeader(
                "已安装命令行工具",
                summary: homebrewStore.hasLoaded && homebrewStore.errorMessage == nil && homebrewStore.brewAvailable
                    ? "\(homebrewStore.formulas.count) 个 formula · \(homebrewStore.hasUnknownFormulaSizes ? "≥" : "")\(ByteCountFormatter.string(fromByteCount: homebrewStore.totalInstalledSize, countStyle: .file))"
                    : nil,
                destination: "命令行工具"
            )
        }
    }

    private func overviewSectionHeader(_ title: String, summary: String?, destination: String) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            Button("管理") { selectedCategory = destination }
                .buttonStyle(.borderless)
                .font(.caption)
        }
    }

    private var homebrewFormulasBySize: [ManagedFormula] {
        homebrewStore.formulas.sorted { lhs, rhs in
            let lhsSize = lhs.sizeBytes ?? -1
            let rhsSize = rhs.sizeBytes ?? -1
            if lhsSize != rhsSize { return lhsSize > rhsSize }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
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
                            Text(entry.action == "move_to_trash" ? "移到废纸篓" : (entry.action == "delete_simulator_device" ? "删除模拟器" : (entry.action == "delete_simulator_runtime" ? "删除模拟器运行时" : entry.action)))
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

private struct HomebrewManagerView: View {
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

private struct HomebrewFormulaRow: View {
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

private struct SimulatorManagerView: View {
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

private struct TemporaryBuildManagerView: View {
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
        .confirmationDialog("确认移到废纸篓？", isPresented: $showingTrashConfirmation, titleVisibility: .visible) {
            Button("移到废纸篓", role: .destructive) {
                Task { await store.trashSelected() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(store.confirmationText)
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
                    ScannedSubfolderList(
                        folders: state.subfolders,
                        indentation: 12,
                        rowSpacing: 10,
                        toggleSelection: toggleSubfolderSelection,
                        isSelected: isSubfolderSelected
                    )
                    .padding(.vertical, 6)
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

private struct ScannedSubfolderList: View {
    @State private var visibleCount = 10

    let folders: [ScannedSubfolder]
    let indentation: CGFloat
    let rowSpacing: CGFloat
    let toggleSelection: (ScannedSubfolder) -> Void
    let isSelected: (String) -> Bool

    private var sortedFolders: [ScannedSubfolder] {
        folders.sorted {
            if $0.size != $1.size { return $0.size > $1.size }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        let displayedFolders = Array(sortedFolders.prefix(visibleCount))
        VStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(displayedFolders) { folder in
                ScannedSubfolderRow(
                    subfolder: folder,
                    toggleSelection: toggleSelection,
                    isSelected: isSelected
                )
            }

            if displayedFolders.count < sortedFolders.count {
                HStack(spacing: 16) {
                    Button("Load more (+10)") {
                        visibleCount = min(visibleCount + 10, sortedFolders.count)
                    }
                    Button("Load all (\(sortedFolders.count))") {
                        visibleCount = sortedFolders.count
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .padding(.top, 2)
            }
        }
        .padding(.leading, indentation)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
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
                ScannedSubfolderList(
                    folders: subfolder.subfolders,
                    indentation: 16,
                    rowSpacing: 9,
                    toggleSelection: toggleSelection,
                    isSelected: isSelected
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
