import AppKit
import Foundation
import Observation

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
