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

struct ManagedSimulatorDevice: Identifiable, Sendable {
    let udid: String
    let name: String
    let runtimeIdentifier: String
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
    var canDelete: Bool {
        isBooted || state.caseInsensitiveCompare("Shutdown") == .orderedSame || !isAvailable
    }
    var deviceTypeName: String {
        deviceTypeIdentifier?.split(separator: ".").last.map { $0.replacingOccurrences(of: "-", with: " ") } ?? "模拟器设备"
    }
}

struct ManagedSimulatorRuntime: Identifiable, Sendable {
    let identifier: String
    let runtimeIdentifier: String
    let name: String
    let version: String
    let build: String
    let sizeBytes: Int64
    let state: String
    let canRemove: Bool
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

private struct SimctlRuntimeImage: Decodable {
    let identifier: String
    let runtimeIdentifier: String
    let version: String
    let build: String
    let sizeBytes: Int64
    let state: String
    let deletable: Bool
}

@MainActor
@Observable
final class SimulatorManagerStore {
    var commandControl: OperationControl?
    private(set) var devices: [ManagedSimulatorDevice] = []
    private(set) var runtimes: [ManagedSimulatorRuntime] = []
    private(set) var isBusy = false
    var scanControl: OperationControl?
    func cancelScan() { scanControl?.cancel() }
    private(set) var hasScanned = false
    private(set) var selectedDeviceIDs: Set<String> = []
    var errorMessage: String?
    var message: String?

    @ObservationIgnored private let cleanupStore: CleanupStore

    init(cleanupStore: CleanupStore) {
        self.cleanupStore = cleanupStore
    }

    var totalDeviceBytes: Int64 { devices.reduce(0) { $0 + $1.totalBytes } }
    var totalRuntimeBytes: Int64 { runtimes.reduce(0) { $0 + $1.sizeBytes } }
    var totalScannedBytes: Int64 { totalDeviceBytes + totalRuntimeBytes }
    var selectedBytes: Int64 {
        devices.filter { selectedDeviceIDs.contains($0.udid) }.reduce(0) { $0 + $1.totalBytes }
    }
    var selectedCount: Int { selectedDeviceIDs.count }
    var selectedBootedCount: Int {
        devices.filter { selectedDeviceIDs.contains($0.udid) && $0.isBooted }.count
    }
    func canDeleteRuntime(_ runtime: ManagedSimulatorRuntime) -> Bool {
        runtime.canRemove && runtime.state.caseInsensitiveCompare("Ready") == .orderedSame
            && !devices.contains { $0.runtimeIdentifier == runtime.runtimeIdentifier }
    }
    func runtimeDeletionBlockReason(_ runtime: ManagedSimulatorRuntime) -> String? {
        if !runtime.canRemove { return "Xcode 当前不允许移除此运行时。" }
        if runtime.state.caseInsensitiveCompare("Ready") != .orderedSame { return "运行时当前状态为“\(runtime.state)”，请稍后重新扫描。" }
        let usingDevices = devices.filter { $0.runtimeIdentifier == runtime.runtimeIdentifier }
        if !usingDevices.isEmpty { return "\(usingDevices.count) 台模拟器仍关联此运行时。请先删除这些设备，避免设备数据变成不可用。" }
        return nil
    }
    func runtimeDeletionConfirmationText(_ runtime: ManagedSimulatorRuntime) -> String {
        "将通过 Xcode 模拟器工具删除 iOS \(runtime.version)（构建 \(runtime.build)）运行时，估算释放 \(ByteCountFormatter.string(fromByteCount: runtime.sizeBytes, countStyle: .file))。此操作不会移到废纸篓；以后需要时可从 Xcode 重新下载。"
    }
    var deletionConfirmationText: String {
        let shutdownNote = selectedBootedCount > 0
            ? "其中正在运行的 \(selectedBootedCount) 台会先关机。"
            : ""
        return "\(shutdownNote)随后通过 Xcode 模拟器管理工具永久删除所选的 \(selectedCount) 台设备及其 App、数据和设置，估算可释放 \(ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file))。此操作不会移到废纸篓。"
    }

    func scan() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        selectedDeviceIDs.removeAll()
        let control = OperationControl(); scanControl = control
        control.report("读取模拟器和运行时清单…")
        defer { isBusy = false; scanControl = nil }
        do {
            let catalog = try await Task.detached(priority: .userInitiated) {
                try Self.loadCatalog(control: control)
            }.value
            try control.check()
            devices = catalog.devices
            runtimes = catalog.runtimes
            hasScanned = true
        } catch {
            devices = []; runtimes = []; hasScanned = false
            errorMessage = error is CancellationError ? "操作已取消，请重新扫描。" : error.localizedDescription
        }
        cleanupStore.recordDiskSnapshot()
    }

    func toggleSelection(_ device: ManagedSimulatorDevice) {
        guard !isBusy, device.canDelete else { return }
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
        let control = OperationControl(); commandControl = control
        control.report("执行模拟器变更…")
        defer { isBusy = false; commandControl = nil }

        let selected = devices.filter { selectedDeviceIDs.contains($0.udid) }
        var deleted: [String] = []
        var failures: [String] = []
        for device in selected {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try Self.deleteDevice(udid: device.udid, control: control)
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
                try Self.loadCatalog(control: control)
            }.value
            devices = catalog.devices
            runtimes = catalog.runtimes
            hasScanned = true
        } catch {
            errorMessage = error is CancellationError ? "操作已取消，请重新扫描。" : error.localizedDescription
        }

        if failures.isEmpty {
            message = "已删除 \(deleted.count) 台模拟器设备。"
        } else {
            message = "已删除 \(deleted.count) 台设备；以下项目失败：\n" + failures.joined(separator: "\n")
        }
    }

    func deleteRuntime(_ runtime: ManagedSimulatorRuntime) async {
        guard !isBusy else { return }
        guard canDeleteRuntime(runtime) else {
            message = runtimeDeletionBlockReason(runtime) ?? "运行时状态已变化，请重新扫描。"
            return
        }
        isBusy = true
        let control = OperationControl(); commandControl = control
        control.report("执行模拟器变更…")
        defer { isBusy = false; commandControl = nil }
        do {
            try await Task.detached(priority: .userInitiated) {
                try Self.deleteRuntimeImage(identifier: runtime.identifier, control: control)
            }.value
            if let logError = cleanupStore.recordSimulatorRuntimeDeletion(runtime) {
                errorMessage = "运行时已删除，但清理记录写入失败：\(logError)"
            }
            let catalog = try await Task.detached(priority: .userInitiated) {
                try Self.loadCatalog(control: control)
            }.value
            devices = catalog.devices
            runtimes = catalog.runtimes
            message = "已提交删除 iOS \(runtime.version) 运行时。"
        } catch {
            message = error.localizedDescription
        }
        cleanupStore.recordDiskSnapshot()
    }

    private nonisolated static func loadCatalog(control: OperationControl? = nil) throws -> (devices: [ManagedSimulatorDevice], runtimes: [ManagedSimulatorRuntime]) {
        let deviceData = try runSimctl(["list", "devices", "--json"], control: control)
        let runtimeData = try runSimctl(["list", "runtimes", "--json"], control: control)
        let runtimeImageData = try runSimctl(["runtime", "list", "--json"], control: control)
        let deviceCatalog = try JSONDecoder().decode(SimctlDeviceCatalog.self, from: deviceData)
        let runtimeCatalog = try JSONDecoder().decode(SimctlRuntimeCatalog.self, from: runtimeData)
        let runtimeImages = try JSONDecoder().decode([String: SimctlRuntimeImage].self, from: runtimeImageData)
        let runtimeByID = Dictionary(uniqueKeysWithValues: runtimeCatalog.runtimes.map { ($0.identifier, $0.name) })
        var devices: [ManagedSimulatorDevice] = []
        for (runtimeIdentifier, entries) in deviceCatalog.devices {
            for entry in entries {
                let runtimeName = runtimeByID[runtimeIdentifier] ?? runtimeIdentifier
                let device = ManagedSimulatorDevice(
                    udid: entry.udid,
                    name: entry.name,
                    runtimeIdentifier: runtimeIdentifier,
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
        let availabilityByID = Dictionary(uniqueKeysWithValues: runtimeCatalog.runtimes.map { ($0.identifier, $0.isAvailable) })
        let runtimes = runtimeImages.map { identifier, image in
            ManagedSimulatorRuntime(
                identifier: identifier,
                runtimeIdentifier: image.runtimeIdentifier,
                name: runtimeByID[image.runtimeIdentifier] ?? "iOS \(image.version)",
                version: image.version,
                build: image.build,
                sizeBytes: image.sizeBytes,
                state: image.state,
                canRemove: image.deletable,
                isAvailable: availabilityByID[image.runtimeIdentifier] ?? true
            )
        }.sorted {
            if $0.name == $1.name { return $0.build.localizedStandardCompare($1.build) == .orderedAscending }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return (devices, runtimes)
    }

    private nonisolated static func deleteRuntimeImage(identifier: String, control: OperationControl? = nil) throws {
        guard UUID(uuidString: identifier) != nil else { throw SimulatorManagerError.invalidRuntimeIdentifier }
        let runtimeData = try runSimctl(["runtime", "list", "--json"], control: control)
        let runtimeImages = try JSONDecoder().decode([String: SimctlRuntimeImage].self, from: runtimeData)
        guard let image = runtimeImages[identifier] else { throw SimulatorManagerError.runtimeNoLongerAvailable }
        guard image.deletable, image.state.caseInsensitiveCompare("Ready") == .orderedSame else {
            throw SimulatorManagerError.runtimeStateChanged
        }

        let deviceData = try runSimctl(["list", "devices", "--json"], control: control)
        let catalog = try JSONDecoder().decode(SimctlDeviceCatalog.self, from: deviceData)
        guard catalog.devices[image.runtimeIdentifier, default: []].isEmpty else {
            throw SimulatorManagerError.runtimeStillHasDevices
        }
        _ = try runSimctl(["runtime", "delete", identifier], control: control)
    }

    private nonisolated static func deleteDevice(udid: String, control: OperationControl? = nil) throws {
        guard UUID(uuidString: udid) != nil else { throw SimulatorManagerError.invalidDeviceIdentifier }
        let deviceData = try runSimctl(["list", "devices", "--json"], control: control)
        let catalog = try JSONDecoder().decode(SimctlDeviceCatalog.self, from: deviceData)
        guard let device = catalog.devices.values.lazy.flatMap({ $0 }).first(where: {
            $0.udid.caseInsensitiveCompare(udid) == .orderedSame
        }) else {
            throw SimulatorManagerError.deviceNoLongerAvailable
        }

        if device.state.caseInsensitiveCompare("Booted") == .orderedSame {
            _ = try runSimctl(["shutdown", udid], control: control)
        } else if device.state.caseInsensitiveCompare("Shutdown") != .orderedSame && device.isAvailable != false {
            throw SimulatorManagerError.deviceStateChanged
        }

        _ = try runSimctl(["delete", udid], control: control)
    }

    private nonisolated static func runSimctl(_ arguments: [String], control: OperationControl? = nil) throws -> Data {
        control?.report("Xcode：" + arguments.joined(separator: " "))
        let result = try CommandRunner.run(executable: "/usr/bin/xcrun", arguments: ["simctl"] + arguments, control: control)
        guard result.status == 0 else {
            let details = String(decoding: result.error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SimulatorManagerError.commandFailed(details.isEmpty ? "xcrun simctl 返回错误。" : details)
        }
        return result.output
    }
}

struct TemporaryBuildArtifact: Identifiable, Sendable {
    let directoryName: String
    let projectName: String
    let size: Int64
    let compilerFileCount: Int
    let fingerprint: DirectoryFingerprint
    let modifiedAt: Date

    var id: String { directoryName }
}

private struct TemporaryBuildInventory: Sendable {
    let artifacts: [TemporaryBuildArtifact]
    let error: String?
}

@MainActor
@Observable
final class TemporaryBuildManagerStore {
    private(set) var artifacts: [TemporaryBuildArtifact] = []
    private(set) var selectedDirectoryNames: Set<String> = []
    private(set) var isBusy = false
    var scanControl: OperationControl?
    func cancelScan() { scanControl?.cancel() }
    private(set) var hasScanned = false
    var errorMessage: String?
    var message: String?

    private let cleanupStore: CleanupStore

    init(cleanupStore: CleanupStore) {
        self.cleanupStore = cleanupStore
    }

    var projectNames: [String] {
        Array(Set(artifacts.map(\.projectName))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    func artifacts(for projectName: String) -> [TemporaryBuildArtifact] {
        artifacts.filter { $0.projectName == projectName }
            .sorted { $0.size > $1.size }
    }

    var selectedCount: Int { selectedDirectoryNames.count }
    var totalBytes: Int64 { artifacts.reduce(0) { $0 + $1.size } }
    var selectedBytes: Int64 {
        artifacts.filter { selectedDirectoryNames.contains($0.directoryName) }
            .reduce(0) { $0 + $1.size }
    }

    var confirmationText: String {
        let selected = artifacts.filter { selectedDirectoryNames.contains($0.directoryName) }
        let names = selected.prefix(5).map(\.directoryName).joined(separator: "、")
        let suffix = selected.count > 5 ? "等 \(selected.count) 个目录" : ""
        return "将把 \(names)\(suffix) 移到废纸篓，约 \(ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file))。这些是按编译产物特征识别的临时目录；如仍需要其中的构建结果，可取消。"
    }

    var cleanupConfirmationItems: [CleanupConfirmationItem] {
        artifacts.filter { selectedDirectoryNames.contains($0.directoryName) }.map {
            CleanupConfirmationItem(id: $0.id, title: $0.projectName, path: "/private/tmp/" + $0.directoryName,
                bytes: $0.size, impact: "编译产物需要重新生成。请先结束相关构建；目录内容有变化时将跳过清理。")
        }
    }

    func toggleSelection(_ artifact: TemporaryBuildArtifact) {
        guard !isBusy else { return }
        if selectedDirectoryNames.contains(artifact.directoryName) {
            selectedDirectoryNames.remove(artifact.directoryName)
        } else {
            selectedDirectoryNames.insert(artifact.directoryName)
        }
    }

    func isSelected(_ artifact: TemporaryBuildArtifact) -> Bool {
        selectedDirectoryNames.contains(artifact.directoryName)
    }

    func isProjectFullySelected(_ projectName: String) -> Bool {
        let projectArtifacts = artifacts(for: projectName)
        return !projectArtifacts.isEmpty && projectArtifacts.allSatisfy { selectedDirectoryNames.contains($0.directoryName) }
    }

    func projectHasSelection(_ projectName: String) -> Bool {
        artifacts(for: projectName).contains { selectedDirectoryNames.contains($0.directoryName) }
    }

    func toggleProjectSelection(_ projectName: String) {
        guard !isBusy else { return }
        let projectArtifacts = artifacts(for: projectName)
        guard !projectArtifacts.isEmpty else { return }
        if isProjectFullySelected(projectName) {
            projectArtifacts.forEach { selectedDirectoryNames.remove($0.directoryName) }
        } else {
            projectArtifacts.forEach { selectedDirectoryNames.insert($0.directoryName) }
        }
    }

    func scan() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        message = nil
        selectedDirectoryNames.removeAll()
        let control = OperationControl(); scanControl = control
        control.report("检查临时构建目录…")
        defer { scanControl = nil }
        do {
            let inventory = try await Task.detached(priority: .userInitiated) {
                try Self.loadInventory(control: control)
            }.value
            try control.check()
            artifacts = inventory.artifacts
            errorMessage = inventory.error
            hasScanned = true
        } catch {
            artifacts = []
            hasScanned = false
            errorMessage = error is CancellationError ? "扫描已取消。" : error.localizedDescription
        }
        cleanupStore.recordDiskSnapshot()
    }

    func trashSelected() async {
        guard !isBusy, !selectedDirectoryNames.isEmpty else { return }
        isBusy = true
        let chosen = artifacts.filter { selectedDirectoryNames.contains($0.directoryName) }
        var moved = 0
        var failures: [String] = []
        for artifact in chosen {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try Self.trash(artifact)
                }.value
                moved += 1
                if let logError = cleanupStore.recordTemporaryBuildDeletion(artifact) {
                    failures.append("\(artifact.directoryName)：已移到废纸篓，但清理记录写入失败（\(logError)）")
                }
                selectedDirectoryNames.remove(artifact.directoryName)
            } catch {
                failures.append("\(artifact.directoryName)：\(error.localizedDescription)")
            }
        }
        isBusy = false
        await scan()
        if failures.isEmpty {
            message = "已将 \(moved) 个临时构建目录移到废纸篓。"
        } else {
            message = "已移动 \(moved) 个目录；以下项目未移动：\n" + failures.joined(separator: "\n")
        }
    }

    private nonisolated static let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).standardizedFileURL
    private nonisolated static let minimumCompilerFileCount = 100
    private nonisolated static let protectedNameFragments = ["release", "review", "archive"]

    private nonisolated static func loadInventory(control: OperationControl? = nil) throws -> TemporaryBuildInventory {
        let manager = FileManager.default
        guard let children = try? manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return TemporaryBuildInventory(artifacts: [], error: "无法读取系统临时目录。")
        }

        let currentUID = getuid()
        var candidates: [(name: String, size: Int64, count: Int, fingerprint: DirectoryFingerprint, modifiedAt: Date)] = []
        var skipped = 0
        for child in children {
            try control?.check()
            do {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
                guard values.isDirectory == true,
                      values.isSymbolicLink != true,
                      try fileOwnerUID(at: child) == currentUID else { continue }
                guard !protectedNameFragments.contains(where: { child.lastPathComponent.localizedCaseInsensitiveContains($0) }) else { continue }
                let fingerprint = try DirectoryFingerprint.capture(child, control: control)
                let result = try inspect(child, ownerUID: currentUID, control: control)
                guard result.safe, result.compilerFileCount >= minimumCompilerFileCount else { continue }
                guard try DirectoryFingerprint.capture(child, control: control) == fingerprint else { skipped += 1; continue }
                candidates.append((child.lastPathComponent, result.size, result.compilerFileCount, fingerprint, values.contentModificationDate ?? .distantPast))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                skipped += 1
            }
        }

        let preferredNames = Dictionary(grouping: candidates, by: { projectKey(for: $0.name) })
            .mapValues { rows in
                rows.map { projectPrefix(for: $0.name) }
                    .max(by: { capitalizationScore($0) < capitalizationScore($1) }) ?? ""
            }
        let artifacts = candidates.map { candidate in
            let key = projectKey(for: candidate.name)
            let label = preferredNames[key] ?? key
            return TemporaryBuildArtifact(
                directoryName: candidate.name,
                projectName: displayProjectName(label),
                size: candidate.size,
                compilerFileCount: candidate.count,
                fingerprint: candidate.fingerprint,
                modifiedAt: candidate.modifiedAt
            )
        }.sorted { $0.size > $1.size }
        let warning = skipped > 0 ? "有 \(skipped) 个目录因无法读取而跳过。" : nil
        return TemporaryBuildInventory(artifacts: artifacts, error: warning)
    }

    private nonisolated static func inspect(_ directory: URL, ownerUID: uid_t, control: OperationControl? = nil) throws -> (safe: Bool, size: Int64, compilerFileCount: Int) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey]
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in enumerationFailed = true; return false }
        ) else { throw TemporaryBuildError.unreadable }
        var size: Int64 = 0
        var compilerFileCount = 0
        while let url = enumerator.nextObject() as? URL {
            try control?.check()
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                return (false, size, compilerFileCount)
            }
            if try fileOwnerUID(at: url) != ownerUID {
                return (false, size, compilerFileCount)
            }
            guard values.isRegularFile == true else { continue }
            size += Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
            if ["o", "pcm", "swiftdeps", "dia"].contains(url.pathExtension.lowercased()) {
                compilerFileCount += 1
            }
        }
        if enumerationFailed { throw TemporaryBuildError.unreadable }
        try control?.check()
        return (true, size, compilerFileCount)
    }

    private nonisolated static func trash(_ artifact: TemporaryBuildArtifact) throws {
        guard !artifact.directoryName.isEmpty,
              !artifact.directoryName.contains("/"),
              artifact.directoryName != ".",
              artifact.directoryName != ".." else { throw TemporaryBuildError.invalidTarget }
        let target = root.appending(path: artifact.directoryName).standardizedFileURL
        guard target.deletingLastPathComponent() == root else { throw TemporaryBuildError.invalidTarget }
        let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true, try fileOwnerUID(at: target) == getuid() else {
            throw TemporaryBuildError.targetChanged
        }
        let result = try inspect(target, ownerUID: getuid())
        guard result.safe, result.compilerFileCount >= minimumCompilerFileCount, result.size == artifact.size else {
            throw TemporaryBuildError.targetChanged
        }
        guard try DirectoryFingerprint.capture(target) == artifact.fingerprint else { throw TemporaryBuildError.targetChanged }
        let current = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard current.isDirectory == true, current.isSymbolicLink != true, try fileOwnerUID(at: target) == getuid() else { throw TemporaryBuildError.targetChanged }
        try FileManager.default.trashItem(at: target, resultingItemURL: nil)
    }

    private nonisolated static func projectKey(for directoryName: String) -> String {
        let lowercased = directoryName.lowercased()
        let stripped = ["-build", "deriveddata"].reduce(lowercased) { value, suffix in
            value.hasSuffix(suffix) ? String(value.dropLast(suffix.count)) : value
        }
        return String(stripped.split(separator: "-", omittingEmptySubsequences: true).first ?? Substring(stripped))
    }

    private nonisolated static func projectPrefix(for directoryName: String) -> String {
        let stripped = ["-build", "deriveddata"].reduce(directoryName) { value, suffix in
            value.lowercased().hasSuffix(suffix) ? String(value.dropLast(suffix.count)) : value
        }
        return String(stripped.split(separator: "-", omittingEmptySubsequences: true).first ?? Substring(stripped))
    }

    private nonisolated static func capitalizationScore(_ name: String) -> Int {
        name.dropFirst().filter(\.isUppercase).count
    }

    private nonisolated static func fileOwnerUID(at url: URL) throws -> uid_t {
        guard let owner = try FileManager.default.attributesOfItem(atPath: url.path)[.ownerAccountID] as? NSNumber else {
            throw TemporaryBuildError.unreadable
        }
        return uid_t(owner.uint32Value)
    }

    private nonisolated static func displayProjectName(_ name: String) -> String {
        guard let first = name.first else { return "未识别项目" }
        return String(first).uppercased() + name.dropFirst()
    }
}

private enum TemporaryBuildError: LocalizedError {
    case unreadable
    case invalidTarget
    case targetChanged

    var errorDescription: String? {
        switch self {
        case .unreadable: "临时构建目录无法完整读取。"
        case .invalidTarget: "临时目录目标无效。"
        case .targetChanged: "目录内容或所有权在扫描后发生变化，请重新扫描。"
        }
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
    case invalidRuntimeIdentifier
    case deviceNoLongerAvailable
    case deviceStateChanged
    case runtimeNoLongerAvailable
    case runtimeStateChanged
    case runtimeStillHasDevices
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .xcodeToolsUnavailable: "无法启动 Xcode 命令行工具。请确认已安装 Xcode，并在 Xcode > Settings > Locations 中选择 Command Line Tools。"
        case .invalidDeviceIdentifier: "模拟器设备标识无效。请重新扫描后再试。"
        case .invalidRuntimeIdentifier: "模拟器运行时标识无效。请重新扫描后再试。"
        case .deviceNoLongerAvailable: "设备在删除前已从清单中消失，请重新扫描。"
        case .deviceStateChanged: "设备正在切换状态，未执行删除。请等待状态稳定后重新扫描。"
        case .runtimeNoLongerAvailable: "运行时在删除前已从清单中消失，请重新扫描。"
        case .runtimeStateChanged: "运行时当前不可删除或状态正在变化，请稍后重新扫描。"
        case .runtimeStillHasDevices: "仍有模拟器设备关联此运行时。请先在模拟器管理中删除这些设备，再移除运行时。"
        case let .commandFailed(details): "Xcode 模拟器命令执行失败：\(details)"
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
