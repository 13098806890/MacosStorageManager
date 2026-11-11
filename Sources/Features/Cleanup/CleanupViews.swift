import SwiftUI
import Charts
import UniformTypeIdentifiers
import os


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
private let tooltipHoverLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "org.cleanupformacos.app",
    category: "TooltipHover"
)

@MainActor
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

@MainActor
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

@MainActor
struct DiskSpaceOverviewView: View {
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

@MainActor
struct CleanupHistoryView: View {
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

@MainActor
struct ConfigurationManagerView: View {
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

@MainActor
struct CleanupRuleRow: View {
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

@MainActor
struct ScannedSubfolderList: View {
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

@MainActor
struct ScannedSubfolderRow: View {
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

@MainActor
struct CleanupConfirmationSheet: View {
    let items: [CleanupConfirmationItem]
    let summary: String
    let isBusy: Bool
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("确认移到废纸篓？").font(.title2.bold())
            Text(summary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(item.title).bold()
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                            }
                            Text(item.path).font(.caption.monospaced()).textSelection(.enabled)
                            Text("清理影响：" + item.impact).font(.callout).foregroundStyle(.secondary)
                            Text("操作：移到废纸篓").font(.caption)
                            Divider()
                        }
                    }
                }
            }
            Text("清理前会重新检查内容；有变化的目标会跳过，需重新扫描。移入废纸篓不代表立即释放空间。")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("确认移到废纸篓", role: .destructive, action: confirm).disabled(isBusy || items.isEmpty)
            }
        }.padding(24).frame(width: 640, height: 540)
    }
}
