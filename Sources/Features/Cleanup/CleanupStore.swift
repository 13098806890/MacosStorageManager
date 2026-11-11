import AppKit
import Foundation
import Observation

struct CleanupConfiguration: Codable {
    let schemaVersion: Int
    let configVersion: String
    let role: String
    let rules: [CleanupRule]
}

struct CleanupRule: Codable, Identifiable {
    let id: String
    let role: String
    let title: String
    let path: String
    let summary: String
    let impact: String
    let risk: CleanupRisk
    let category: String
    let subfolderDescriptions: [String: String]?

    var resolvedPath: URL? {
        guard path.hasPrefix("$HOME/") else { return nil }
        let suffix = String(path.dropFirst("$HOME/".count))
        let components = suffix.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              components.allSatisfy({ $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._ -".contains($0)) } }),
              Self.isApproved(relativePath: suffix) else { return nil }

        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let resolved = home.appending(path: suffix).standardizedFileURL
        guard resolved.path.hasPrefix(home.path + "/") else { return nil }
        return resolved
    }

    private static let approvedRoots = [
        "Library/Developer/Xcode/DerivedData",
        "Library/Developer/Xcode/DocumentationCache",
        "Library/Developer/Xcode/iOS DeviceSupport",
        "Library/Developer/CoreSimulator/Caches",
        "Library/Caches/org.swift.swiftpm",
        "Library/Caches/Yarn",
        "Library/Caches/pip",
        "Library/Caches/CocoaPods",
        "Library/Caches/go-build",
        "Library/Caches/Homebrew",
        "Library/Caches/Google/Chrome/Default/Cache",
        "Library/Caches/Google/Chrome/Default/Code Cache",
        "Library/Caches/Firefox/Profiles",
        "Library/Caches/vscode-cpptools",
        "Library/Caches/node-gyp",
        "Library/Caches/org.carthage.CarthageKit",
        "Library/Application Support/Adobe/Common/Media Cache Files",
        ".npm/_cacache",
        ".pub-cache/hosted/pub.dev",
        ".dartServer/.analysis-driver",
        ".cargo/registry/cache",
        ".cargo/registry/src",
        ".gradle/wrapper/dists",
        ".gradle/caches"
    ]

    static func isApproved(relativePath: String) -> Bool {
        approvedRoots.contains { relativePath == $0 || relativePath.hasPrefix($0 + "/") }
    }
}

struct CleanupProfile: Codable, Identifiable {
    let id: String
    let name: String
    let isBundled: Bool
    let configuration: CleanupConfiguration
    var enabledRuleIDs: Set<String>

    var role: String { configuration.role }
    var configVersion: String { configuration.configVersion }
    var rules: [CleanupRule] { configuration.rules.filter { $0.role == configuration.role } }
}

struct ConfiguredCleanupRule: Identifiable {
    let profileID: String
    let profileName: String
    let configVersion: String
    let rule: CleanupRule

    var id: String { "\(profileID)::\(rule.id)" }
}

struct DiskSpaceSnapshot: Codable, Identifiable {
    let timestamp: Date
    let totalBytes: Int64
    let availableBytes: Int64

    var id: Date { timestamp }
    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }

    static func current() -> DiskSpaceSnapshot? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacity else { return nil }
        return DiskSpaceSnapshot(timestamp: Date(), totalBytes: Int64(total), availableBytes: Int64(available))
    }
}

struct ScannedSubfolder: Identifiable, Sendable {
    let name: String
    let relativePath: String
    let size: Int64
    let description: String?
    let subfolders: [ScannedSubfolder]

    var id: String { relativePath }
}

private enum ConfigurationImportError: LocalizedError {
    case unsupportedSchema
    case invalidRules
    case duplicateRuleID
    case duplicateProfile(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "只支持 schemaVersion 1 的配置。"
        case .invalidRules: "配置没有当前角色的有效规则，或包含不受支持的路径。"
        case .duplicateRuleID: "配置中有重复的规则 ID。"
        case let .duplicateProfile(name): "已存在同名配置“\(name)”。"
        }
    }
}

struct CleanupSelection: Hashable {
    let ruleID: String
    let subfolderPath: String?

    static func toggling(_ target: Self, in selections: Set<Self>) -> Set<Self> {
        if selections.contains(target) { return selections.subtracting([target]) }
        var result = selections.filter { existing in
            guard existing.ruleID == target.ruleID else { return true }
            guard let lhs = existing.subfolderPath, let rhs = target.subfolderPath else { return false }
            return !(lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/"))
        }
        result.insert(target)
        return result
    }
}

enum CleanupRisk: String, Codable {
    case low
    case medium

    var label: String { self == .low ? "低风险" : "中风险" }
}

struct CleanupConfirmationItem: Identifiable {
    let id: String
    let title: String
    let path: String
    let bytes: Int64
    let impact: String
}

struct ScanState {
    var size: Int64?
    var subfolders: [ScannedSubfolder]
    var isScanning = false
    var error: String?
    var fingerprints: [String: DirectoryFingerprint] = [:]

    init(size: Int64? = nil, subfolders: [ScannedSubfolder] = [], isScanning: Bool = false, error: String? = nil) {
        self.size = size
        self.subfolders = subfolders
        self.isScanning = isScanning
        self.error = error
    }
}

struct CleanupLogEntry: Codable, Identifiable, Sendable {
    let timestamp: Date
    let ruleID: String
    let title: String
    let contents: String
    let resolvedPath: String
    let scannedBytes: Int64
    let action: String
    let consent: String
    let result: String
    let configVersion: String

    var id: String { "\(timestamp.timeIntervalSince1970)-\(ruleID)-\(action)-\(resolvedPath)" }
}

@MainActor
@Observable
final class CleanupStore {
    private(set) var profiles: [CleanupProfile] = []
    private(set) var rules: [ConfiguredCleanupRule] = []
    private(set) var states: [String: ScanState] = [:]
    private(set) var diskSnapshots: [DiskSpaceSnapshot] = []
    private(set) var currentDiskSpace: DiskSpaceSnapshot?
    private(set) var cleanupLogEntries: [CleanupLogEntry] = []
    private(set) var cleanupLogError: String?
    private var selectedForCleanup: Set<CleanupSelection> = []
    private(set) var isBusy = false
    var scanControl: OperationControl?
    func cancelScan() { scanControl?.cancel() }
    private(set) var configVersion = ""
    var message: String?

    init() {
        loadConfiguration()
        loadDiskHistory()
        refreshCleanupLog()
    }

    @discardableResult
    func reloadBundledConfiguration() -> Bool {
        guard let url = Bundle.main.url(forResource: "cleanup-rules", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let configuration = try? JSONDecoder().decode(CleanupConfiguration.self, from: data),
              configuration.schemaVersion == 1 else {
            message = "无法重新读取内置清理配置。"
            return false
        }

        let previousRules = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0.rule) })
        let previousStates = states
        let previousSelections = selectedForCleanup

        let allBundledIDs = Set(configuration.rules.filter { $0.role == configuration.role }.map(\.id))
        let savedBundledIDs = UserDefaults.standard.stringArray(forKey: "enabledRules.builtin-\(configuration.role)").map(Set.init) ?? allBundledIDs
        let bundled = CleanupProfile(
            id: "builtin-\(configuration.role)",
            name: "\(configuration.role)（内置）",
            isBundled: true,
            configuration: configuration,
            enabledRuleIDs: savedBundledIDs.intersection(allBundledIDs)
        )
        let importedProfiles = profiles.filter { !$0.isBundled }
        profiles = [bundled] + importedProfiles
        configVersion = configuration.configVersion
        rebuildRules()

        let unchangedRuleIDs = Set(rules.compactMap { configuredRule -> String? in
            guard let previousRule = previousRules[configuredRule.id],
                  previousRule.path == configuredRule.rule.path,
                  previousRule.subfolderDescriptions == configuredRule.rule.subfolderDescriptions else { return nil }
            return configuredRule.id
        })
        states = previousStates.filter { unchangedRuleIDs.contains($0.key) }
        selectedForCleanup = previousSelections.filter {
            unchangedRuleIDs.contains($0.ruleID) && (states[$0.ruleID]?.size ?? 0) > 0
        }
        return true
    }

    var statusText: String { "已启用 \(rules.count) 条规则 · 清理记录保存在本机" }
    var scannedSelectionCount: Int { selectedForCleanup.count }
    var selectedSizeDescription: String {
        let bytes = selectedForCleanup.reduce(Int64.zero) { total, selection in
            guard let state = states[selection.ruleID] else { return total }
            let selectedSize = selection.subfolderPath.flatMap { path in Self.findSubfolder(path, in: state.subfolders)?.size } ?? (selection.subfolderPath == nil ? state.size : nil)
            return total + (selectedSize ?? 0)
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    var cleanupConfirmationItems: [CleanupConfirmationItem] {
        rules.flatMap { configured -> [CleanupConfirmationItem] in
            guard let state = states[configured.id], state.error == nil else { return [] }
            return selectedForCleanup.filter { $0.ruleID == configured.id }.map { selection in
                let folder = selection.subfolderPath.flatMap { Self.findSubfolder($0, in: state.subfolders) }
                return CleanupConfirmationItem(id: configured.id + (selection.subfolderPath ?? ""),
                    title: configured.rule.title,
                    path: configured.rule.path + (selection.subfolderPath.map { "/" + $0 } ?? ""),
                    bytes: folder?.size ?? state.size ?? 0, impact: configured.rule.impact)
            }.sorted { $0.path < $1.path }
        }
    }

    var cleanupConfirmationText: String {
        "将所选的 \(scannedSelectionCount) 个缓存目录或子目录（约 \(selectedSizeDescription)）移到废纸篓。应用会记录规则、路径、扫描大小和操作结果。"
    }

    func scanAll(rules: [ConfiguredCleanupRule]) async {
        guard !isBusy, !rules.isEmpty else { return }
        isBusy = true
        let control = OperationControl(); scanControl = control
        defer { isBusy = false; scanControl = nil }
        for (index, rule) in rules.enumerated() {
            do { try control.check() } catch { break }
            control.report("扫描 \(index + 1)/\(rules.count)：\(rule.rule.title)")
            await scanRule(rule)
        }
        recordDiskSnapshot()
    }

    func toggleSelection(_ configuredRule: ConfiguredCleanupRule) {
        guard !isBusy, states[configuredRule.id]?.error == nil, states[configuredRule.id]?.size ?? 0 > 0 else { return }
        let selection = CleanupSelection(ruleID: configuredRule.id, subfolderPath: nil)
        selectedForCleanup = CleanupSelection.toggling(selection, in: selectedForCleanup)
    }

    func toggleSubfolderSelection(_ subfolder: ScannedSubfolder, in configuredRule: ConfiguredCleanupRule) {
        guard !isBusy, states[configuredRule.id]?.error == nil,
              states[configuredRule.id]?.fingerprints[subfolder.relativePath] != nil, subfolder.size > 0 else { return }
        let selection = CleanupSelection(ruleID: configuredRule.id, subfolderPath: subfolder.relativePath)
        selectedForCleanup = CleanupSelection.toggling(selection, in: selectedForCleanup)
    }

    func isSelected(_ configuredRule: ConfiguredCleanupRule, subfolderPath: String? = nil) -> Bool {
        selectedForCleanup.contains(CleanupSelection(ruleID: configuredRule.id, subfolderPath: subfolderPath))
    }

    func scan(_ configuredRule: ConfiguredCleanupRule) async {
        guard !isBusy else { return }
        isBusy = true
        scanControl = OperationControl()
        defer { isBusy = false; scanControl = nil }
        await scanRule(configuredRule)
        recordDiskSnapshot()
    }

    private func scanRule(_ configuredRule: ConfiguredCleanupRule) async {
        let rule = configuredRule.rule
        guard let expectedURL = rule.resolvedPath else {
            states[configuredRule.id] = ScanState(error: "配置路径无效或不受支持。")
            return
        }
        states[configuredRule.id] = ScanState(isScanning: true)
        selectedForCleanup = selectedForCleanup.filter { $0.ruleID != configuredRule.id }
        let control = scanControl
        do {
            guard FileManager.default.fileExists(atPath: expectedURL.path) else {
                states[configuredRule.id] = ScanState(error: "这个目录当前不存在。")
                return
            }
            try Self.rejectSymbolicLink(at: expectedURL)
            try ensureTargetResolvesInsideHome(expectedURL)
            let result = try await Task.detached(priority: .userInitiated) {
                let fingerprints = try DirectoryFingerprint.captureTree(expectedURL, control: control)
                let result = try Self.directoryBreakdown(at: expectedURL, descriptions: rule.subfolderDescriptions ?? [:], control: control)
                guard try DirectoryFingerprint.capture(expectedURL, control: control) == fingerprints[""] else { throw OperationFailure.changed }
                try control?.check()
                return (result, fingerprints)
            }.value
            try control?.check()
            states[configuredRule.id] = ScanState(size: result.0.size, subfolders: result.0.subfolders)
            states[configuredRule.id]?.fingerprints = result.1
            selectedForCleanup = selectedForCleanup.filter { $0.ruleID != configuredRule.id }
        } catch {
            states[configuredRule.id] = ScanState(error: error is CancellationError ? "扫描已取消，请重新扫描。" : error.localizedDescription)
        }
    }

    func cleanScannedRules() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let chosen = rules.flatMap { configuredRule -> [(ConfiguredCleanupRule, ScannedSubfolder?, Int64)] in
            guard let state = states[configuredRule.id] else { return [] }
            if selectedForCleanup.contains(CleanupSelection(ruleID: configuredRule.id, subfolderPath: nil)), let size = state.size {
                return [(configuredRule, nil, size)]
            }
            return Self.flatten(state.subfolders).compactMap { subfolder in
                selectedForCleanup.contains(CleanupSelection(ruleID: configuredRule.id, subfolderPath: subfolder.relativePath))
                    ? (configuredRule, subfolder, subfolder.size) : nil
            }
        }
        var cleaned = 0
        var failures: [String] = []

        for (configuredRule, subfolder, scannedBytes) in chosen {
            let rule = configuredRule.rule
            guard let rootURL = rule.resolvedPath, scannedBytes > 0 else { continue }
            let expectedURL = subfolder.map { rootURL.appending(path: $0.relativePath).standardizedFileURL } ?? rootURL
            let displayTitle = subfolder.map { "\(rule.title) / \($0.relativePath)" } ?? rule.title
            let contents = subfolder.map { $0.description ?? "未配置子文件夹说明（父目录说明：\(rule.summary)）" } ?? rule.summary
            do {
                guard FileManager.default.fileExists(atPath: expectedURL.path) else {
                    throw CleanupError.targetNoLongerExists
                }
                try Self.rejectSymbolicLinksAlongPath(from: rootURL, to: expectedURL)
                try ensureTargetResolvesInsideHome(expectedURL)
                guard let scannedFingerprint = states[configuredRule.id]?.fingerprints[subfolder?.relativePath ?? ""] else { throw OperationFailure.changed }
                try await Task.detached(priority: .userInitiated) {
                    try DirectoryFingerprint.requireUnchanged(expectedURL, expected: scannedFingerprint)
                }.value
                try Self.rejectSymbolicLinksAlongPath(from: rootURL, to: expectedURL)
                try ensureTargetResolvesInsideHome(expectedURL)
                try FileManager.default.trashItem(at: expectedURL, resultingItemURL: nil)
                let logError = appendLog(configuredRule: configuredRule, title: displayTitle, contents: contents, path: expectedURL.path, bytes: scannedBytes, result: "moved_to_trash")
                selectedForCleanup.remove(CleanupSelection(ruleID: configuredRule.id, subfolderPath: subfolder?.relativePath))
                if let subfolder {
                    selectedForCleanup = selectedForCleanup.filter {
                        guard $0.ruleID == configuredRule.id, let selectedPath = $0.subfolderPath else { return true }
                        return !Self.pathsOverlap(selectedPath, subfolder.relativePath)
                    }
                    do {
                        let result = try await Task.detached(priority: .userInitiated) {
                            try Self.directoryBreakdown(at: rootURL, descriptions: rule.subfolderDescriptions ?? [:])
                        }.value
                        let fingerprints = states[configuredRule.id]?.fingerprints ?? [:]
                        states[configuredRule.id] = ScanState(size: result.size, subfolders: result.subfolders)
                        states[configuredRule.id]?.fingerprints = fingerprints
                    } catch {
                        // The Trash operation already succeeded. Do not report it as a failed move.
                        selectedForCleanup = selectedForCleanup.filter { $0.ruleID != configuredRule.id }
                        states[configuredRule.id] = ScanState(error: "已移到废纸篓，但刷新目录失败。请重新扫描。")
                        failures.append("\(displayTitle)：已移到废纸篓，但刷新目录失败。")
                    }
                } else {
                    selectedForCleanup = selectedForCleanup.filter { $0.ruleID != configuredRule.id }
                    states[configuredRule.id] = ScanState(size: 0)
                }
                cleaned += 1
                if let logError { failures.append("\(displayTitle)：已移到废纸篓，但清理记录写入失败（\(logError)）") }
            } catch {
                selectedForCleanup = selectedForCleanup.filter { $0.ruleID != configuredRule.id }
                states[configuredRule.id] = ScanState(error: error.localizedDescription)
                let logError = appendLog(configuredRule: configuredRule, title: displayTitle, contents: contents, path: expectedURL.path, bytes: scannedBytes, result: "failed: \(error.localizedDescription)")
                failures.append("\(displayTitle)：\(error.localizedDescription)")
                if let logError { failures.append("清理记录写入失败：\(logError)") }
            }
        }

        if failures.isEmpty {
            message = "已将 \(cleaned) 个目录移到废纸篓。"
        } else {
            message = "已完成 \(cleaned) 项；以下项目失败：\n" + failures.joined(separator: "\n")
        }
    }

    func showLatestLog() {
        let url = logURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            message = "还没有清理记录。完成首次清理后会生成 cleanup-log.jsonl。"
        }
    }

    func refreshCleanupLog() {
        let url = logURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            cleanupLogEntries = []
            cleanupLogError = nil
            return
        }
        do {
            let data = try Data(contentsOf: url)
            var entries: [CleanupLogEntry] = []
            var invalidLineCount = 0
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                do {
                    entries.append(try JSONDecoder().decode(CleanupLogEntry.self, from: Data(line)))
                } catch {
                    invalidLineCount += 1
                }
            }
            cleanupLogEntries = entries.sorted { $0.timestamp > $1.timestamp }
            cleanupLogError = invalidLineCount == 0 ? nil : "有 \(invalidLineCount) 条记录无法读取，其余记录仍可查看。"
        } catch {
            cleanupLogEntries = []
            cleanupLogError = "读取清理记录失败：\(error.localizedDescription)"
        }
    }

    private func ensureTargetResolvesInsideHome(_ target: URL) throws {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
        let targetPath = target.standardizedFileURL.resolvingSymlinksInPath().path
        guard targetPath.hasPrefix(homePath + "/") else { throw CleanupError.pathResolvesOutsideApprovedCache }
        let relativePath = String(targetPath.dropFirst(homePath.count + 1))
        guard CleanupRule.isApproved(relativePath: relativePath) else {
            throw CleanupError.pathResolvesOutsideApprovedCache
        }
    }

    private func appendLog(configuredRule: ConfiguredCleanupRule, title: String, contents: String, path: String, bytes: Int64, result: String) -> String? {
        let entry = CleanupLogEntry(timestamp: Date(), ruleID: "\(configuredRule.profileID)::\(configuredRule.rule.id)", title: title, contents: contents, resolvedPath: path, scannedBytes: bytes, action: "move_to_trash", consent: "user_confirmed", result: result, configVersion: configuredRule.configVersion)
        return writeLogEntry(entry)
    }

    func recordSimulatorDeviceDeletion(_ device: ManagedSimulatorDevice) -> String? {
        let entry = CleanupLogEntry(
            timestamp: Date(),
            ruleID: "simulator-device-\(device.udid.lowercased())",
            title: "Xcode 模拟器 · \(device.name)",
            contents: "\(device.runtimeName) / \(device.deviceTypeName)。删除会清除模拟器中的 App、App 数据和设备设置。",
            resolvedPath: device.dataPath ?? "",
            scannedBytes: device.totalBytes,
            action: "delete_simulator_device",
            consent: "user_confirmed",
            result: "deleted_with_simctl",
            configVersion: configVersion
        )
        return writeLogEntry(entry)
    }

    func recordSimulatorRuntimeDeletion(_ runtime: ManagedSimulatorRuntime) -> String? {
        let entry = CleanupLogEntry(
            timestamp: Date(),
            ruleID: "simulator-runtime-\(runtime.identifier.lowercased())",
            title: "Xcode 模拟器运行时 · \(runtime.name)",
            contents: "版本 \(runtime.version)，构建 \(runtime.build)。移除后需要时可从 Xcode 重新下载。",
            resolvedPath: "",
            scannedBytes: runtime.sizeBytes,
            action: "delete_simulator_runtime",
            consent: "user_confirmed",
            result: "deleted_with_simctl",
            configVersion: configVersion
        )
        return writeLogEntry(entry)
    }

    func recordTemporaryBuildDeletion(_ artifact: TemporaryBuildArtifact) -> String? {
        let entry = CleanupLogEntry(
            timestamp: Date(),
            ruleID: "temporary-build-artifact",
            title: "临时构建 · \(artifact.projectName)",
            contents: "包含 \(artifact.compilerFileCount) 个编译产物；目录名：\(artifact.directoryName)。",
            resolvedPath: "private-tmp/\(artifact.directoryName)",
            scannedBytes: artifact.size,
            action: "move_to_trash",
            consent: "user_confirmed",
            result: "moved_to_trash",
            configVersion: configVersion
        )
        return writeLogEntry(entry)
    }

    private func writeLogEntry(_ entry: CleanupLogEntry) -> String? {
        do {
            let data = try JSONEncoder().encode(entry)
            let line = data + Data([0x0A])
            let url = logURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } else {
                try line.write(to: url, options: .atomic)
            }
            cleanupLogEntries.insert(entry, at: 0)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private nonisolated static func rejectSymbolicLink(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true { throw CleanupError.symbolicLinkNotAllowed }
    }

    nonisolated static func rejectSymbolicLinksAlongPath(from root: URL, to target: URL) throws {
        guard target.standardizedFileURL.path == root.standardizedFileURL.path || target.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw CleanupError.pathResolvesOutsideApprovedCache }
        try Self.rejectSymbolicLink(at: root)
        let relative = String(target.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
        var current = root
        for component in relative.split(separator: "/") {
            current.append(path: String(component))
            try Self.rejectSymbolicLink(at: current)
        }
    }

    private var logURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "CleanUpForMacOS/cleanup-log.jsonl")
    }

    func importConfigurations(from urls: [URL]) {
        var imported: [CleanupProfile] = []
        for url in urls {
            let hasScopedAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasScopedAccess { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                let configuration = try JSONDecoder().decode(CleanupConfiguration.self, from: data)
                guard configuration.schemaVersion == 1 else { throw ConfigurationImportError.unsupportedSchema }
                let validRules = configuration.rules.filter { $0.role == configuration.role }
                guard !validRules.isEmpty,
                      validRules.count == configuration.rules.count,
                      validRules.allSatisfy({ $0.resolvedPath != nil }) else {
                    throw ConfigurationImportError.invalidRules
                }
                guard Set(validRules.map(\.id)).count == validRules.count else {
                    throw ConfigurationImportError.duplicateRuleID
                }
                let candidate = CleanupProfile(id: UUID().uuidString, name: url.deletingPathExtension().lastPathComponent, isBundled: false, configuration: configuration, enabledRuleIDs: [])
                guard !profiles.contains(where: { $0.name.localizedCaseInsensitiveCompare(candidate.name) == .orderedSame }) else {
                    throw ConfigurationImportError.duplicateProfile(candidate.name)
                }
                guard !imported.contains(where: { $0.name.localizedCaseInsensitiveCompare(candidate.name) == .orderedSame }) else {
                    throw ConfigurationImportError.duplicateProfile(candidate.name)
                }
                imported.append(candidate)
            } catch {
                message = "无法导入 \(url.lastPathComponent)：\(error.localizedDescription)"
                return
            }
        }
        profiles.append(contentsOf: imported)
        rebuildRules()
        saveProfiles()
        message = "已导入 \(imported.count) 份配置。启用需要的规则后，它们会出现在扫描列表中。"
    }

    func setRuleEnabled(_ enabled: Bool, ruleID: String, profileID: String) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        guard let rule = profiles[index].rules.first(where: { $0.id == ruleID }) else { return }
        let configuredID = "\(profileID)::\(ruleID)"
        if enabled {
            if let overlapping = rules.first(where: { $0.id != configuredID && pathsOverlap($0.rule.path, rule.path) }) {
                message = "无法启用“\(rule.title)”：它与已启用规则“\(overlapping.rule.title)”的路径重复或存在父子包含关系。"
                return
            }
            profiles[index].enabledRuleIDs.insert(ruleID)
        } else {
            profiles[index].enabledRuleIDs.remove(ruleID)
            states.removeValue(forKey: configuredID)
            selectedForCleanup = selectedForCleanup.filter { $0.ruleID != configuredID }
        }
        rebuildRules()
        if profiles[index].isBundled {
            UserDefaults.standard.set(Array(profiles[index].enabledRuleIDs), forKey: "enabledRules.\(profileID)")
        } else {
            saveProfiles()
        }
    }

    func removeProfile(_ profileID: String) {
        guard let profile = profiles.first(where: { $0.id == profileID }), !profile.isBundled else { return }
        let removedIDs = Set(profile.rules.map { "\(profile.id)::\($0.id)" })
        profiles.removeAll { $0.id == profileID }
        states = states.filter { !removedIDs.contains($0.key) }
        selectedForCleanup = selectedForCleanup.filter { !removedIDs.contains($0.ruleID) }
        rebuildRules()
        saveProfiles()
    }

    func recordDiskSnapshot() {
        guard let snapshot = DiskSpaceSnapshot.current() else { return }
        currentDiskSpace = snapshot
        diskSnapshots.append(snapshot)
        if diskSnapshots.count > 365 { diskSnapshots.removeFirst(diskSnapshots.count - 365) }
        do {
            let data = try JSONEncoder().encode(diskSnapshots)
            try FileManager.default.createDirectory(at: diskHistoryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: diskHistoryURL, options: .atomic)
        } catch {
            message = "磁盘空间已读取，但历史记录写入失败：\(error.localizedDescription)"
        }
    }

    private func loadConfiguration() {
        guard let url = Bundle.main.url(forResource: "cleanup-rules", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let configuration = try? JSONDecoder().decode(CleanupConfiguration.self, from: data),
              configuration.schemaVersion == 1 else {
            message = "无法读取内置清理配置。"
            return
        }
        let allBundledIDs = Set(configuration.rules.filter { $0.role == configuration.role }.map(\.id))
        let savedBundledIDs = UserDefaults.standard.stringArray(forKey: "enabledRules.builtin-\(configuration.role)").map(Set.init) ?? allBundledIDs
        let bundled = CleanupProfile(id: "builtin-\(configuration.role)", name: "\(configuration.role)（内置）", isBundled: true, configuration: configuration, enabledRuleIDs: savedBundledIDs.intersection(allBundledIDs))
        let imported = (try? Data(contentsOf: profilesURL)).flatMap { try? JSONDecoder().decode([CleanupProfile].self, from: $0) } ?? []
        profiles = [bundled] + imported.filter { !$0.isBundled }
        configVersion = configuration.configVersion
        rebuildRules()
    }

    private func rebuildRules() {
        rules = profiles.flatMap { profile in
            profile.rules.filter { profile.enabledRuleIDs.contains($0.id) }.map {
                ConfiguredCleanupRule(profileID: profile.id, profileName: profile.name, configVersion: profile.configVersion, rule: $0)
            }
        }
    }

    private func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }

    private func saveProfiles() {
        let imported = profiles.filter { !$0.isBundled }
        do {
            let data = try JSONEncoder().encode(imported)
            try FileManager.default.createDirectory(at: profilesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: profilesURL, options: .atomic)
        } catch {
            message = "配置已在当前会话更新，但保存失败：\(error.localizedDescription)"
        }
    }

    private func loadDiskHistory() {
        diskSnapshots = (try? Data(contentsOf: diskHistoryURL)).flatMap { try? JSONDecoder().decode([DiskSpaceSnapshot].self, from: $0) } ?? []
        currentDiskSpace = DiskSpaceSnapshot.current() ?? diskSnapshots.last
    }

    private var profilesURL: URL { supportDirectory.appending(path: "profiles.json") }
    private var diskHistoryURL: URL { supportDirectory.appending(path: "disk-space-history.json") }
    private var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "CleanUpForMacOS")
    }

    nonisolated static func directoryBreakdown(at url: URL, descriptions: [String: String], control: OperationControl? = nil) throws -> (size: Int64, subfolders: [ScannedSubfolder]) {
        let tree = try scanDirectory(at: url, relativePath: "", descriptions: descriptions, control: control)
        return (tree.size, tree.subfolders)
    }

    private nonisolated static func scanDirectory(at url: URL, relativePath: String, descriptions: [String: String], control: OperationControl?) throws -> (size: Int64, subfolders: [ScannedSubfolder]) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey]
        try control?.check()
        let children: [URL]
        do { children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) }
        catch { throw OperationFailure.unreadable }
        var total: Int64 = 0
        var subfolders: [ScannedSubfolder] = []
        for childURL in children {
            try control?.check()
            let values: URLResourceValues
            do { values = try childURL.resourceValues(forKeys: keys) } catch { throw OperationFailure.unreadable }
            guard values.isSymbolicLink != true else { continue }
            if values.isDirectory == true {
                let name = childURL.lastPathComponent
                let childPath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
                let result = try scanDirectory(at: childURL, relativePath: childPath, descriptions: descriptions, control: control)
                total += result.size
                subfolders.append(ScannedSubfolder(name: name, relativePath: childPath, size: result.size, description: relativePath.isEmpty ? descriptions[name] : nil, subfolders: result.subfolders))
            } else if values.isRegularFile == true {
                total += Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
            }
        }
        subfolders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (total, subfolders)
    }

    private nonisolated static func flatten(_ folders: [ScannedSubfolder]) -> [ScannedSubfolder] {
        folders.flatMap { [$0] + flatten($0.subfolders) }
    }

    private nonisolated static func findSubfolder(_ path: String, in folders: [ScannedSubfolder]) -> ScannedSubfolder? {
        for folder in folders {
            if folder.relativePath == path { return folder }
            if let found = findSubfolder(path, in: folder.subfolders) { return found }
        }
        return nil
    }

    private nonisolated static func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }

}

private enum CleanupError: LocalizedError {
    case symbolicLinkNotAllowed
    case pathResolvesOutsideApprovedCache
    case targetNoLongerExists

    var errorDescription: String? {
        switch self {
        case .symbolicLinkNotAllowed: "为避免误删，当前规则不接受符号链接目录。"
        case .pathResolvesOutsideApprovedCache: "为避免访问未批准的内容，此路径解析后不在已批准的缓存目录内。"
        case .targetNoLongerExists: "这个目录在扫描后已不存在，请重新扫描。"
        }
    }
}
