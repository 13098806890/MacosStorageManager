import Foundation
import Observation

struct ManagedFormula: Identifiable, Hashable {
    let name: String
    let installedVersion: String
    let sizeBytes: Int64?
    let isOutdated: Bool
    let isPinned: Bool

    var id: String { name }
}

enum HomebrewAction: Identifiable {
    case install(String)
    case upgrade(String)
    case uninstall(String)
    case pin(String)
    case unpin(String)

    var id: String {
        switch self {
        case let .install(name): "install:\(name)"
        case let .upgrade(name): "upgrade:\(name)"
        case let .uninstall(name): "uninstall:\(name)"
        case let .pin(name): "pin:\(name)"
        case let .unpin(name): "unpin:\(name)"
        }
    }

    var formulaName: String {
        switch self {
        case let .install(name), let .upgrade(name), let .uninstall(name), let .pin(name), let .unpin(name): name
        }
    }

    var title: String {
        switch self {
        case .install: "确认安装命令行工具？"
        case .upgrade: "确认升级命令行工具？"
        case .uninstall: "确认卸载命令行工具？"
        case .pin: "确认固定当前版本？"
        case .unpin: "确认解除版本固定？"
        }
    }

    var buttonTitle: String {
        switch self {
        case .install: "安装"
        case .upgrade: "升级"
        case .uninstall: "卸载"
        case .pin: "固定版本"
        case .unpin: "解除固定"
        }
    }

    var confirmationMessage: String {
        switch self {
        case let .install(name): "Homebrew 将安装 formula「\(name)」及其所需依赖。"
        case let .upgrade(name): "Homebrew 将升级 formula「\(name)」；依赖关系可能导致其他 formula 也发生变化。"
        case let .uninstall(name): "Homebrew 将卸载 formula「\(name)」。依赖项默认会保留；依赖该工具的软件可能无法正常工作。"
        case let .pin(name): "Homebrew 将固定「\(name)」当前已安装的版本。固定期间，常规升级会跳过它，也可能错过安全更新。"
        case let .unpin(name): "Homebrew 将解除「\(name)」的版本固定；后续升级可能将它更新到新版本。"
        }
    }

    var isDestructive: Bool {
        if case .uninstall = self { return true }
        return false
    }
}

@MainActor
@Observable
final class HomebrewManagerStore {
    private(set) var formulas: [ManagedFormula] = []
    private(set) var searchResults: [String] = []
    private(set) var isBusy = false
    var operationControl: OperationControl?
    private(set) var canCancelOperation = false
    func cancelOperation() { if canCancelOperation { operationControl?.cancel() } }
    private(set) var hasLoaded = false
    private(set) var brewAvailable = false
    private(set) var brewVersion = ""
    var searchText = ""
    var errorMessage: String?
    var message: String?

    private var brewPath: String?

    var outdatedCount: Int { formulas.filter(\.isOutdated).count }
    var totalInstalledSize: Int64 { formulas.compactMap(\.sizeBytes).reduce(0, +) }
    var hasUnknownFormulaSizes: Bool { formulas.contains { $0.sizeBytes == nil } }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        let control = OperationControl(); operationControl = control
        canCancelOperation = true
        control.report("等待 Homebrew…")
        errorMessage = nil
        defer { isBusy = false; operationControl = nil; canCancelOperation = false }

        do {
            let catalog = try await Task.detached(priority: .userInitiated) {
                try Self.loadCatalog(control: control)
            }.value
            try control.check()
            brewPath = catalog.path
            brewVersion = catalog.version
            formulas = catalog.formulas
            brewAvailable = true
            hasLoaded = true
        } catch {
            // Keep the last complete inventory on cancellation/failure; do not report "not installed".
            hasLoaded = true
            errorMessage = error is CancellationError ? "查询已取消，请刷新后重试。" : error.localizedDescription
        }
    }

    func search() async {
        guard !isBusy else { return }
        guard let brewPath else {
            errorMessage = "未找到 Homebrew。请先安装 Homebrew，再刷新清单。"
            return
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSafeFormulaName(query) else {
            errorMessage = "请输入由字母、数字、@、点、加号、减号或斜线组成的 formula 名称。"
            return
        }

        isBusy = true
        let control = OperationControl(); operationControl = control
        canCancelOperation = true
        control.report("等待 Homebrew…")
        errorMessage = nil
        searchResults = []
        defer { isBusy = false; operationControl = nil; canCancelOperation = false }
        do {
            let results = try await Task.detached(priority: .userInitiated) {
                let output = try Self.run(brewPath: brewPath, arguments: ["search", "--formula", query], control: control)
                return output.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter(Self.isSafeFormulaName)
                    .uniqued()
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            }.value
            try control.check()
            searchResults = results
            if results.isEmpty { message = "没有找到匹配的 Homebrew formula。" }
        } catch {
            errorMessage = error is CancellationError ? "查询已取消，请刷新后重试。" : error.localizedDescription
        }
    }

    func perform(_ action: HomebrewAction) async {
        guard !isBusy, let brewPath, Self.isSafeFormulaName(action.formulaName) else { return }
        isBusy = true
        let control = OperationControl(); operationControl = control
        canCancelOperation = true
        control.report("等待 Homebrew…")
        errorMessage = nil
        message = nil
        canCancelOperation = false
        control.report("正在执行 Homebrew 变更，请勿退出应用…")
        defer { isBusy = false; operationControl = nil; canCancelOperation = false }

        let arguments: [String]
        switch action {
        case let .install(name): arguments = ["install", "--formula", name]
        case let .upgrade(name): arguments = ["upgrade", "--formula", name]
        case let .uninstall(name): arguments = ["uninstall", "--formula", name]
        case let .pin(name): arguments = ["pin", name]
        case let .unpin(name): arguments = ["unpin", name]
        }

        do {
            let actionName = action.buttonTitle
            _ = try await Task.detached(priority: .userInitiated) {
                try Self.run(brewPath: brewPath, arguments: arguments, control: control, timeout: 900)
            }.value
            await refreshAfterAction()
            message = "已\(actionName)：\(action.formulaName)"
        } catch {
            let failure = error is CancellationError ? "操作已取消。" : error.localizedDescription
            await refreshAfterAction()
            errorMessage = failure + " 请核对刷新后的工具状态；操作可能已部分生效。"
        }
    }

    func isInstalled(_ name: String) -> Bool {
        formulas.contains { $0.name == name }
    }

    private func refreshAfterAction() async {
        // Keep the busy state owned by the operation and refresh the data in place.
        guard let brewPath else { return }
        let control = operationControl
        do {
            let catalog = try await Task.detached(priority: .userInitiated) {
                try Self.loadCatalog(using: brewPath, control: control)
            }.value
            brewVersion = catalog.version
            formulas = catalog.formulas
            brewAvailable = true
            hasLoaded = true
        } catch {
            errorMessage = error is CancellationError ? "查询已取消，请刷新后重试。" : error.localizedDescription
        }
    }

    private nonisolated static func loadCatalog(using knownPath: String? = nil, control: OperationControl? = nil) throws -> (path: String, version: String, formulas: [ManagedFormula]) {
        guard let path = knownPath ?? locateBrew() else { throw HomebrewManagerError.notInstalled }
        let versionOutput = try run(brewPath: path, arguments: ["--version"], control: control)
        let cellarOutput = try run(brewPath: path, arguments: ["--cellar"], control: control)
        let installedOutput = try run(brewPath: path, arguments: ["list", "--formula", "--versions"], control: control)
        let outdatedOutput = try run(brewPath: path, arguments: ["outdated", "--formula", "--quiet"], control: control)
        let pinnedOutput = try run(brewPath: path, arguments: ["list", "--pinned"], control: control)

        let outdated = Set(outdatedOutput.split(whereSeparator: \.isNewline).map(String.init))
        let pinned = Set(pinnedOutput.split(whereSeparator: \.isNewline).map(String.init))
        let cellar = URL(fileURLWithPath: cellarOutput.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
        let formulas = try installedOutput.split(whereSeparator: \.isNewline).compactMap { line -> ManagedFormula? in
            try control?.check()
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let name = parts.first, isSafeFormulaName(name), parts.count > 1 else { return nil }
            let cellarName = name.split(separator: "/").last.map(String.init) ?? name
            let formulaDirectory = cellar.appendingPathComponent(cellarName, isDirectory: true)
            return ManagedFormula(
                name: name,
                installedVersion: parts.dropFirst().joined(separator: ", "),
                sizeBytes: try directoryAllocatedSize(at: formulaDirectory, control: control),
                isOutdated: outdated.contains(name),
                isPinned: pinned.contains(name)
            )
        }.sorted {
            if $0.isOutdated != $1.isOutdated { return $0.isOutdated }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let version = versionOutput.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Homebrew"
        return (path, version, formulas)
    }

    private nonisolated static func directoryAllocatedSize(at url: URL, control: OperationControl?) throws -> Int64? {
        try control?.check()
        var isDirectory: ObjCBool = false
        var failed = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey, .fileSizeKey],
                errorHandler: { _, _ in failed = true; return false }
              ) else { return nil }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            try control?.check()
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey, .fileSizeKey]) else { failed = true; continue }
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            total += Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
        return failed ? nil : total
    }

    private nonisolated static func locateBrew() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private nonisolated static func isSafeFormulaName(_ name: String) -> Bool {
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        guard let first = name.unicodeScalars.first,
              isASCIIAlphanumeric(first),
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              name.unicodeScalars.allSatisfy({
                  isASCIIAlphanumeric($0) || "@._+/-".unicodeScalars.contains($0)
              }) else {
            return false
        }
        return true
    }

    private nonisolated static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value) || (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    @discardableResult
    private nonisolated static func run(brewPath: String, arguments: [String], control: OperationControl? = nil, timeout: TimeInterval = 120) throws -> String {
        control?.report("Homebrew：" + arguments.joined(separator: " "))
        var environment = ProcessInfo.processInfo.environment
        let prefix = URL(fileURLWithPath: brewPath).deletingLastPathComponent().deletingLastPathComponent().path
        environment["PATH"] = "\(prefix)/bin:\(prefix)/sbin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
        let result = try CommandRunner.run(executable: brewPath, arguments: arguments, environment: environment, timeout: timeout, control: control)
        let output = String(decoding: result.output, as: UTF8.self)
        guard result.status == 0 else {
            let detail = String(decoding: result.error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw HomebrewManagerError.commandFailed(detail.isEmpty ? output : detail)
        }
        return output
    }
}

private enum HomebrewManagerError: LocalizedError {
    case notInstalled
    case cannotLaunch(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: "未在 Apple Silicon 或 Intel Mac 的标准位置找到 Homebrew（/opt/homebrew 或 /usr/local）。"
        case let .cannotLaunch(details): "无法启动 Homebrew：\(details)"
        case let .commandFailed(details): "Homebrew 操作失败：\(details)"
        }
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
