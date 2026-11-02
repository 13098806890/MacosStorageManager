import Foundation
import Observation

struct ManagedFormula: Identifiable, Hashable {
    let name: String
    let installedVersion: String
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
    private(set) var hasLoaded = false
    private(set) var brewAvailable = false
    private(set) var brewVersion = ""
    var searchText = ""
    var errorMessage: String?
    var message: String?

    private var brewPath: String?

    var outdatedCount: Int { formulas.filter(\.isOutdated).count }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            let catalog = try await Task.detached(priority: .userInitiated) {
                try Self.loadCatalog()
            }.value
            brewPath = catalog.path
            brewVersion = catalog.version
            formulas = catalog.formulas
            brewAvailable = true
            hasLoaded = true
        } catch {
            brewPath = nil
            formulas = []
            brewAvailable = false
            hasLoaded = true
            errorMessage = error.localizedDescription
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
        errorMessage = nil
        searchResults = []
        defer { isBusy = false }
        do {
            let results = try await Task.detached(priority: .userInitiated) {
                let output = try Self.run(brewPath: brewPath, arguments: ["search", "--formula", query])
                return output.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter(Self.isSafeFormulaName)
                    .uniqued()
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            }.value
            searchResults = results
            if results.isEmpty { message = "没有找到匹配的 Homebrew formula。" }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func perform(_ action: HomebrewAction) async {
        guard !isBusy, let brewPath, Self.isSafeFormulaName(action.formulaName) else { return }
        isBusy = true
        errorMessage = nil
        message = nil
        defer { isBusy = false }

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
                try Self.run(brewPath: brewPath, arguments: arguments)
            }.value
            await refreshAfterAction()
            message = "已\(actionName)：\(action.formulaName)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func isInstalled(_ name: String) -> Bool {
        formulas.contains { $0.name == name }
    }

    private func refreshAfterAction() async {
        // Keep the busy state owned by the operation and refresh the data in place.
        guard let brewPath else { return }
        do {
            let catalog = try await Task.detached(priority: .userInitiated) {
                try Self.loadCatalog(using: brewPath)
            }.value
            brewVersion = catalog.version
            formulas = catalog.formulas
            brewAvailable = true
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private nonisolated static func loadCatalog(using knownPath: String? = nil) throws -> (path: String, version: String, formulas: [ManagedFormula]) {
        guard let path = knownPath ?? locateBrew() else { throw HomebrewManagerError.notInstalled }
        let versionOutput = try run(brewPath: path, arguments: ["--version"])
        let installedOutput = try run(brewPath: path, arguments: ["list", "--formula", "--versions"])
        let outdatedOutput = try run(brewPath: path, arguments: ["outdated", "--formula", "--quiet"])
        let pinnedOutput = try run(brewPath: path, arguments: ["list", "--pinned"])

        let outdated = Set(outdatedOutput.split(whereSeparator: \.isNewline).map(String.init))
        let pinned = Set(pinnedOutput.split(whereSeparator: \.isNewline).map(String.init))
        let formulas = installedOutput.split(whereSeparator: \.isNewline).compactMap { line -> ManagedFormula? in
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let name = parts.first, isSafeFormulaName(name), parts.count > 1 else { return nil }
            return ManagedFormula(
                name: name,
                installedVersion: parts.dropFirst().joined(separator: ", "),
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

    private nonisolated static func loadCatalog() throws -> (path: String, version: String, formulas: [ManagedFormula]) {
        try loadCatalog(using: nil)
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
    private nonisolated static func run(brewPath: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brewPath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        let prefix = URL(fileURLWithPath: brewPath).deletingLastPathComponent().deletingLastPathComponent().path
        environment["PATH"] = "\(prefix)/bin:\(prefix)/sbin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        do {
            try process.run()
        } catch {
            throw HomebrewManagerError.cannotLaunch(error.localizedDescription)
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HomebrewManagerError.commandFailed(detail.isEmpty ? "Homebrew 命令退出，状态码 \(process.terminationStatus)。" : detail)
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
