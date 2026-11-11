import SwiftUI


@main
@MainActor
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

@MainActor
private struct CleanupHomeView: View {
    @State private var store: CleanupStore
    @State private var simulatorStore: SimulatorManagerStore
    @State private var temporaryBuildStore: TemporaryBuildManagerStore
    @State private var homebrewStore = HomebrewManagerStore()
    @State private var selectedCategory: String? = "全部"
    @State private var isFullScanInProgress = false
    @State private var fullScanTask: Task<Void, Never>?
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
        .sheet(isPresented: $showingCleanupConfirmation) {
            CleanupConfirmationSheet(items: store.cleanupConfirmationItems, summary: store.cleanupConfirmationText,
                isBusy: store.isBusy,
                cancel: { showingCleanupConfirmation = false },
                confirm: {
                    showingCleanupConfirmation = false
                    Task { await store.cleanScannedRules() }
                })
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
            ToolbarItem(placement: .automatic) {
                if let control = store.scanControl ?? simulatorStore.scanControl ?? temporaryBuildStore.scanControl ?? homebrewStore.operationControl ?? simulatorStore.commandControl {
                    TimelineView(.periodic(from: .now, by: 0.3)) { _ in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(control.status).lineLimit(2)
                            Text("已用 \(Int(Date().timeIntervalSince(control.startedAt))) 秒").foregroundStyle(.secondary)
                        }.font(.caption).frame(maxWidth: 260).help(control.status)
                    }
                    if store.scanControl != nil || simulatorStore.scanControl != nil || temporaryBuildStore.scanControl != nil || homebrewStore.canCancelOperation {
                        Button("取消扫描/查询") {
                            fullScanTask?.cancel()
                            store.cancelScan(); simulatorStore.cancelScan(); temporaryBuildStore.cancelScan(); homebrewStore.cancelOperation()
                        }
                    }
                }
            }
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
                    .disabled(isFullScanInProgress || store.isBusy || simulatorStore.isBusy || temporaryBuildStore.isBusy || homebrewStore.isBusy)
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
        fullScanTask = Task {
            defer { isFullScanInProgress = false; fullScanTask = nil }
            await store.scanAll(rules: rulesToScan)
            guard !Task.isCancelled else { return }
            await simulatorStore.scan()
            guard !Task.isCancelled else { return }
            await temporaryBuildStore.scan()
            guard !Task.isCancelled else { return }
            await homebrewStore.refresh()
            store.refreshCleanupLog()
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
