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
        ".npm/_cacache",
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
    let size: Int64
    let description: String?

    var id: String { name }
}

struct ManagedSimulatorDevice: Identifiable, Sendable {
    let udid: String
    let name: String
    let runtimeName: String
    let deviceTypeIdentifier: String?
    let state: String
    let isAvailable: Bool
    let dataPath: String?
    let dataBytes: Int64
    let logBytes: Int64

    var id: String { udid }
    var totalBytes: Int64 { dataBytes + logBytes }
    var isBooted: Bool { state.caseInsensitiveCompare("Booted") == .orderedSame }
    var canDelete: Bool { !isBooted && (state == "Shutdown" || !isAvailable) }
    var deviceTypeName: String {
        deviceTypeIdentifier?.split(separator: ".").last.map { $0.replacingOccurrences(of: "-", with: " ") } ?? "模拟器设备"
    }
}

struct ManagedSimulatorRuntime: Identifiable, Sendable {
    let identifier: String
    let name: String
    let version: String
    let isAvailable: Bool

    var id: String { identifier }
}

private struct SimctlDeviceCatalog: Decodable {
    let devices: [String: [SimctlDevice]]
}

private struct SimctlDevice: Decodable {
    let udid: String
    let name: String
    let state: String
    let isAvailable: Bool?
    let dataPath: String?
    let dataPathSize: Int64?
    let logPathSize: Int64?
    let deviceTypeIdentifier: String?
}

private struct SimctlRuntimeCatalog: Decodable {
    let runtimes: [SimctlRuntime]
}

private struct SimctlRuntime: Decodable {
    let identifier: String
    let name: String
    let version: String
    let isAvailable: Bool
}

@MainActor
@Observable
final class SimulatorManagerStore {
    private(set) var devices: [ManagedSimulatorDevice] = []
    private(set) var runtimes: [ManagedSimulatorRuntime] = []
    private(set) var isBusy = false
    private(set) var hasScanned = false
    private(set) var selectedDeviceIDs: Set<String> = []
    var errorMessage: String?
    var message: String?

    @ObservationIgnored private let cleanupStore: CleanupStore

    init(cleanupStore: CleanupStore) {
        self.cleanupStore = cleanupStore
    }

    var totalDeviceBytes: Int64 { devices.reduce(0) { $0 + $1.totalBytes } }
    var selectedBytes: Int64 {
        devices.filter { selectedDeviceIDs.contains($0.udid) }.reduce(0) { $0 + $1.totalBytes }
    }
    var selectedCount: Int { selectedDeviceIDs.count }
    var deletionConfirmationText: String {
        "将通过 Xcode 的模拟器管理工具删除所选的 \(selectedCount) 台设备及其 App、数据和设置，估算可释放 \(ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file))。此操作不会移到废纸篓。"
    }

    func scan() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        selectedDeviceIDs.removeAll()
        defer { isBusy = false }
        do {
            let catalog = try await Task.detached(priority: .userInitiated) {
                try Self.loadCatalog()
            }.value
            devices = catalog.devices
            runtimes = catalog.runtimes
            hasScanned = true
        } catch {
            errorMessage = error.localizedDescription
        }
        cleanupStore.recordDiskSnapshot()
    }

    func toggleSelection(_ device: ManagedSimulatorDevice) {
        guard device.canDelete else { return }
        if selectedDeviceIDs.contains(device.udid) {
            selectedDeviceIDs.remove(device.udid)
        } else {
            selectedDeviceIDs.insert(device.udid)
        }
    }

    func isSelected(_ device: ManagedSimulatorDevice) -> Bool {
        selectedDeviceIDs.contains(device.udid)
    }

    func deleteSelected() async {
        guard !isBusy, !selectedDeviceIDs.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }

        let selected = devices.filter { selectedDeviceIDs.contains($0.udid) && $0.canDelete }
        var deleted: [String] = []
        var failures: [String] = []
        for device in selected {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try Self.deleteDevice(udid: device.udid)
                }.value
                if let logError = cleanupStore.recordSimulatorDeviceDeletion(device) {
                    failures.append("\(device.name)：设备已删除，但清理记录写入失败（\(logError)）")
                }
                deleted.append(device.name)
                selectedDeviceIDs.remove(device.udid)
            } catch {
                failures.append("\(device.name)：\(error.localizedDescription)")
            }
        }

        do {
            let catalog = try await Task.detached(priority: .userInitiated) {
                try Self.loadCatalog()
            }.value
            devices = catalog.devices
            runtimes = catalog.runtimes
            hasScanned = true
        } catch {
            errorMessage = error.localizedDescription
        }

        if failures.isEmpty {
            message = "已删除 \(deleted.count) 台模拟器设备。"
        } else {
            message = "已删除 \(deleted.count) 台设备；以下项目失败：\n" + failures.joined(separator: "\n")
        }
    }

    private nonisolated static func loadCatalog() throws -> (devices: [ManagedSimulatorDevice], runtimes: [ManagedSimulatorRuntime]) {
        let deviceData = try runSimctl(["list", "devices", "--json"])
        let runtimeData = try runSimctl(["list", "runtimes", "--json"])
        let deviceCatalog = try JSONDecoder().decode(SimctlDeviceCatalog.self, from: deviceData)
        let runtimeCatalog = try JSONDecoder().decode(SimctlRuntimeCatalog.self, from: runtimeData)
        let runtimeByID = Dictionary(uniqueKeysWithValues: runtimeCatalog.runtimes.map { ($0.identifier, $0.name) })
        var devices: [ManagedSimulatorDevice] = []
        for (runtimeIdentifier, entries) in deviceCatalog.devices {
            for entry in entries {
                let runtimeName = runtimeByID[runtimeIdentifier] ?? runtimeIdentifier
                let device = ManagedSimulatorDevice(
                    udid: entry.udid,
                    name: entry.name,
                    runtimeName: runtimeName,
                    deviceTypeIdentifier: entry.deviceTypeIdentifier,
                    state: entry.state,
                    isAvailable: entry.isAvailable ?? true,
                    dataPath: entry.dataPath,
                    dataBytes: entry.dataPathSize ?? 0,
                    logBytes: entry.logPathSize ?? 0
                )
                devices.append(device)
            }
        }
        devices.sort { lhs, rhs in
            if lhs.totalBytes == rhs.totalBytes {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return lhs.totalBytes > rhs.totalBytes
        }
        let runtimes = runtimeCatalog.runtimes.map {
            ManagedSimulatorRuntime(identifier: $0.identifier, name: $0.name, version: $0.version, isAvailable: $0.isAvailable)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (devices, runtimes)
    }

    private nonisolated static func deleteDevice(udid: String) throws {
        guard UUID(uuidString: udid) != nil else { throw SimulatorManagerError.invalidDeviceIdentifier }
        _ = try runSimctl(["delete", udid])
    }

    private nonisolated static func runSimctl(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw SimulatorManagerError.xcodeToolsUnavailable
        }
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let details = String(data: errorOutput, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SimulatorManagerError.commandFailed(details?.isEmpty == false ? details! : "xcrun simctl 返回错误。")
        }
        return output
    }
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

private enum SimulatorManagerError: LocalizedError {
    case xcodeToolsUnavailable
    case invalidDeviceIdentifier
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .xcodeToolsUnavailable: "无法启动 Xcode 命令行工具。请确认已安装 Xcode，并在 Xcode > Settings > Locations 中选择 Command Line Tools。"
        case .invalidDeviceIdentifier: "模拟器设备标识无效。请重新扫描后再试。"
        case let .commandFailed(details): "Xcode 模拟器命令执行失败：\(details)"
        }
    }
}

private struct CleanupSelection: Hashable {
    let ruleID: String
    let subfolderName: String?
}

enum CleanupRisk: String, Codable {
    case low
    case medium

    var label: String { self == .low ? "低风险" : "注意影响" }
}

struct ScanState {
    var size: Int64?
    var subfolders: [ScannedSubfolder]
    var isScanning = false
    var error: String?

    init(size: Int64? = nil, subfolders: [ScannedSubfolder] = [], isScanning: Bool = false, error: String? = nil) {
        self.size = size
        self.subfolders = subfolders
        self.isScanning = isScanning
        self.error = error
    }
}

private struct CleanupLogEntry: Encodable {
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
}

@MainActor
@Observable
final class CleanupStore {
    private(set) var profiles: [CleanupProfile] = []
    private(set) var rules: [ConfiguredCleanupRule] = []
    private(set) var states: [String: ScanState] = [:]
    private(set) var diskSnapshots: [DiskSpaceSnapshot] = []
    private(set) var currentDiskSpace: DiskSpaceSnapshot?
    private var selectedForCleanup: Set<CleanupSelection> = []
    private(set) var isBusy = false
    private(set) var configVersion = ""
    var message: String?

    init() {
        loadConfiguration()
        loadDiskHistory()
    }

    var statusText: String { "已启用 \(rules.count) 条规则 · 清理记录保存在本机" }
    var scannedSelectionCount: Int { selectedForCleanup.count }
    var selectedSizeDescription: String {
        let bytes = selectedForCleanup.reduce(Int64.zero) { total, selection in
            guard let state = states[selection.ruleID] else { return total }
            let selectedSize = selection.subfolderName.flatMap { name in state.subfolders.first { $0.name == name }?.size } ?? (selection.subfolderName == nil ? state.size : nil)
            return total + (selectedSize ?? 0)
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    var cleanupConfirmationText: String {
        "将所选的 \(scannedSelectionCount) 个缓存目录或子目录（约 \(selectedSizeDescription)）移到废纸篓。应用会记录规则、路径、扫描大小和操作结果。"
    }

    func scanAll(rules: [ConfiguredCleanupRule]) async {
        guard !rules.isEmpty else { return }
        for rule in rules { await scanRule(rule) }
        recordDiskSnapshot()
    }

    func toggleSelection(_ configuredRule: ConfiguredCleanupRule) {
        let selection = CleanupSelection(ruleID: configuredRule.id, subfolderName: nil)
        guard states[configuredRule.id]?.size ?? 0 > 0 else { return }
        if selectedForCleanup.contains(selection) {
            selectedForCleanup.remove(selection)
        } else {
            selectedForCleanup = selectedForCleanup.filter { $0.ruleID != configuredRule.id }
            selectedForCleanup.insert(selection)
        }
    }

    func toggleSubfolderSelection(_ subfolder: ScannedSubfolder, in configuredRule: ConfiguredCleanupRule) {
        guard subfolder.size > 0 else { return }
        let selection = CleanupSelection(ruleID: configuredRule.id, subfolderName: subfolder.name)
        if selectedForCleanup.contains(selection) {
            selectedForCleanup.remove(selection)
        } else {
            selectedForCleanup.remove(CleanupSelection(ruleID: configuredRule.id, subfolderName: nil))
            selectedForCleanup.insert(selection)
        }
    }

    func isSelected(_ configuredRule: ConfiguredCleanupRule, subfolderName: String? = nil) -> Bool {
        selectedForCleanup.contains(CleanupSelection(ruleID: configuredRule.id, subfolderName: subfolderName))
    }

    func scan(_ configuredRule: ConfiguredCleanupRule) async {
        await scanRule(configuredRule)
        recordDiskSnapshot()
    }

    private func scanRule(_ configuredRule: ConfiguredCleanupRule) async {
        guard !isBusy else { return }
        let rule = configuredRule.rule
        guard let expectedURL = rule.resolvedPath else {
            states[configuredRule.id] = ScanState(error: "配置路径无效或不受支持。")
            return
        }
        isBusy = true
        states[configuredRule.id] = ScanState(isScanning: true)
        defer { isBusy = false }

        do {
            guard FileManager.default.fileExists(atPath: expectedURL.path) else {
                states[configuredRule.id] = ScanState(error: "这个目录当前不存在。")
                return
            }
            try rejectSymbolicLink(at: expectedURL)
            try ensureTargetResolvesInsideHome(expectedURL)
            let result = await Task.detached(priority: .userInitiated) {
                Self.directoryBreakdown(at: expectedURL, descriptions: rule.subfolderDescriptions ?? [:])
            }.value
            states[configuredRule.id] = ScanState(size: result.size, subfolders: result.subfolders)
            selectedForCleanup = selectedForCleanup.filter { $0.ruleID != configuredRule.id }
        } catch {
            states[configuredRule.id] = ScanState(error: error.localizedDescription)
        }
    }

    func cleanScannedRules() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let chosen = rules.flatMap { configuredRule -> [(ConfiguredCleanupRule, ScannedSubfolder?, Int64)] in
            guard let state = states[configuredRule.id] else { return [] }
            if selectedForCleanup.contains(CleanupSelection(ruleID: configuredRule.id, subfolderName: nil)), let size = state.size {
                return [(configuredRule, nil, size)]
            }
            return state.subfolders.compactMap { subfolder in
                selectedForCleanup.contains(CleanupSelection(ruleID: configuredRule.id, subfolderName: subfolder.name))
                    ? (configuredRule, subfolder, subfolder.size)
                    : nil
            }
        }
        var cleaned = 0
        var failures: [String] = []

        for (configuredRule, subfolder, scannedBytes) in chosen {
            let rule = configuredRule.rule
            guard let rootURL = rule.resolvedPath, scannedBytes > 0 else { continue }
            let expectedURL = subfolder.map { rootURL.appending(path: $0.name).standardizedFileURL } ?? rootURL
            let displayTitle = subfolder.map { "\(rule.title) / \($0.name)" } ?? rule.title
            let contents = subfolder.map { $0.description ?? "未配置子文件夹说明（父目录说明：\(rule.summary)）" } ?? rule.summary
            do {
                guard FileManager.default.fileExists(atPath: expectedURL.path) else {
                    throw CleanupError.targetNoLongerExists
                }
                try rejectSymbolicLink(at: expectedURL)
                try ensureTargetResolvesInsideHome(expectedURL)
                try FileManager.default.trashItem(at: expectedURL, resultingItemURL: nil)
                let logError = appendLog(configuredRule: configuredRule, title: displayTitle, contents: contents, path: expectedURL.path, bytes: scannedBytes, result: "moved_to_trash")
                selectedForCleanup.remove(CleanupSelection(ruleID: configuredRule.id, subfolderName: subfolder?.name))
                if let subfolder {
                    if var state = states[configuredRule.id] {
                        state.size = max(0, (state.size ?? 0) - scannedBytes)
                        state.subfolders.removeAll { $0.name == subfolder.name }
                        states[configuredRule.id] = state
                    }
                } else {
                    selectedForCleanup = selectedForCleanup.filter { $0.ruleID != configuredRule.id }
                    states[configuredRule.id] = ScanState(size: 0)
                }
                cleaned += 1
                if let logError { failures.append("\(displayTitle)：已移到废纸篓，但清理记录写入失败（\(logError)）") }
            } catch {
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
            NSWorkspace.shared.open(url)
        } else {
            message = "还没有清理记录。"
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
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func rejectSymbolicLink(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true { throw CleanupError.symbolicLinkNotAllowed }
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

    private nonisolated static func directoryBreakdown(at url: URL, descriptions: [String: String]) -> (size: Int64, subfolders: [ScannedSubfolder]) {
        let directoryKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let fileKeys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(directoryKeys), options: [.skipsHiddenFiles]) else {
            return (0, [])
        }
        let childNames = children.compactMap { childURL -> String? in
            guard let values = try? childURL.resourceValues(forKeys: directoryKeys),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else { return nil }
            return childURL.lastPathComponent
        }
        var childSizes = Dictionary(uniqueKeysWithValues: childNames.map { ($0, Int64.zero) })
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(fileKeys), options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else {
            return (0, childNames.sorted().map { ScannedSubfolder(name: $0, size: 0, description: descriptions[$0]) })
        }
        var total: Int64 = 0
        for case let itemURL as URL in enumerator {
            guard let values = try? itemURL.resourceValues(forKeys: fileKeys), values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            let bytes = Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
            total += bytes
            let relativePath = String(itemURL.standardizedFileURL.path.dropFirst(url.standardizedFileURL.path.count + 1))
            if let firstComponent = relativePath.split(separator: "/").first,
               let current = childSizes[String(firstComponent)] {
                childSizes[String(firstComponent)] = current + bytes
            }
        }
        let subfolders = childNames.map { name in
            ScannedSubfolder(name: name, size: childSizes[name] ?? 0, description: descriptions[name])
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (total, subfolders)
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
