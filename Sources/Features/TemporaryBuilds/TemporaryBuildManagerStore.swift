import AppKit
import Foundation
import Observation

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
    private nonisolated static let runningBundlePath = Bundle.main.bundleURL
        .resolvingSymlinksInPath()
        .standardizedFileURL
        .path
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
                      try fileOwnerUID(at: child) == currentUID,
                      !containsRunningApplication(at: child) else { continue }
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
        guard !containsRunningApplication(at: target) else { throw TemporaryBuildError.runningApplication }
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

    private nonisolated static func containsRunningApplication(at directory: URL) -> Bool {
        let directoryPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        return runningBundlePath == directoryPath || runningBundlePath.hasPrefix(directoryPath + "/")
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
    case runningApplication

    var errorDescription: String? {
        switch self {
        case .unreadable: "临时构建目录无法完整读取。"
        case .invalidTarget: "临时目录目标无效。"
        case .targetChanged: "目录内容或所有权在扫描后发生变化，请重新扫描。"
        case .runningApplication: "不能清理当前应用所在目录。"
        }
    }
}
