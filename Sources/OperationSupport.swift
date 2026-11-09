import Foundation
import CryptoKit
import Darwin

/// Cooperative cancellation is offered only for read-only operations.
final class OperationControl: @unchecked Sendable {
    let startedAt = Date()
    private let lock = NSLock()
    private var stopped = false
    private var text = "准备中…"
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    func check() throws { lock.lock(); let value = stopped; lock.unlock(); if value { throw CancellationError() } }
    func report(_ value: String) {
        lock.lock(); text = String(value.replacingOccurrences(of: NSHomeDirectory(), with: "$HOME").suffix(2000)); lock.unlock()
    }
    var status: String { lock.lock(); defer { lock.unlock() }; return text }
}

enum OperationFailure: LocalizedError {
    case unreadable, changed, timedOut, outputTooLarge
    var errorDescription: String? {
        switch self {
        case .unreadable: return "扫描不完整：部分内容无法读取。请检查权限后重新扫描；此结果不能用于清理。"
        case .changed: return "目录内容在扫描后发生变化，已跳过清理。请重新扫描、检查并确认。"
        case .timedOut: return "操作超时，已请求停止命令。若操作涉及安装或删除，结果可能已部分生效，请刷新检查后再试。"
        case .outputTooLarge: return "命令输出超出限制，已停止。请刷新检查操作结果。"
        }
    }
}

struct CommandResult { let output: Data; let error: Data; let status: Int32 }

enum CommandRunner {
    /// Both pipes are drained without blocking, including when a descendant holds a pipe open.
    static func run(executable: String, arguments: [String], environment: [String: String]? = nil,
                    timeout: TimeInterval = 120, control: OperationControl? = nil) throws -> CommandResult {
        try control?.check()
        let process = Process(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments; process.environment = environment
        process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        let outFD = stdout.fileHandleForReading.fileDescriptor, errFD = stderr.fileHandleForReading.fileDescriptor
        _ = fcntl(outFD, F_SETFL, O_NONBLOCK); _ = fcntl(errFD, F_SETFL, O_NONBLOCK)
        defer { try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close() }
        var out = Data(), err = Data(), failure: Error?, stopAt: Date?
        let deadline = Date().addingTimeInterval(timeout)
        func drain(_ fd: Int32, into data: inout Data) {
            var buffer = [UInt8](repeating: 0, count: 16384)
            // Bound each pass so continuous output cannot starve timeout/cancel checks.
            for _ in 0..<64 {
                let count = Darwin.read(fd, &buffer, buffer.count)
                guard count > 0 else { break }
                if data.count + count <= 32 * 1024 * 1024 { data.append(contentsOf: buffer.prefix(count)) }
                else { failure = OperationFailure.outputTooLarge; break }
                control?.report(String(decoding: data.suffix(2000), as: UTF8.self))
            }
        }
        while true {
            drain(outFD, into: &out); drain(errFD, into: &err)
            if !process.isRunning { break }
            if failure == nil {
                do { try control?.check() } catch { failure = error }
                if Date() >= deadline { failure = OperationFailure.timedOut }
            }
            if failure != nil {
                let pid = process.processIdentifier
                // Foundation may give the child its own group. Never signal our own group.
                let target = getpgid(pid) == pid ? -pid : pid
                if stopAt == nil { _ = kill(target, SIGTERM); stopAt = Date() }
                else if Date().timeIntervalSince(stopAt!) > 2 { _ = kill(target, SIGKILL) }
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        try control?.check()
        if let failure { throw failure }
        return CommandResult(output: out, error: err, status: process.terminationStatus)
    }
}

/// Metadata fingerprint, including hidden entries. It does not read file contents or follow symlinks.
/// Used only to reject stale cleanup proposals, not as an atomic filesystem guarantee.
struct DirectoryFingerprint: Equatable, Sendable {
    let digest: Data
    static func capture(_ root: URL, control: OperationControl? = nil) throws -> Self {
        try captureTree(root, control: control)[""]!
    }

    static func requireUnchanged(_ root: URL, expected: Self) throws {
        guard try capture(root) == expected else { throw OperationFailure.changed }
    }

    static func captureTree(_ root: URL, control: OperationControl? = nil) throws -> [String: Self] {
        var tree: [String: Self] = [:]
        var inspected = 0
        func visit(_ url: URL, relative: String) throws -> Self {
            try control?.check()
            inspected += 1
            if inspected % 500 == 0 { control?.report("检查目录状态：已检查 \(inspected) 项…") }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw OperationFailure.unreadable }
            var hash = SHA256()
            let metadata = "\(info.st_dev)|\(info.st_ino)|\(info.st_mode)|\(info.st_uid)|\(info.st_size)|\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)|\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)\n"
            hash.update(data: Data(metadata.utf8))
            if info.st_mode & S_IFMT == S_IFDIR {
                let children: [URL]
                do { children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) }
                catch { throw OperationFailure.unreadable }
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let name = child.lastPathComponent
                    hash.update(data: Data("\(name.utf8.count):\(name)".utf8))
                    hash.update(data: try visit(child, relative: relative.isEmpty ? name : relative + "/" + name).digest)
                }
            }
            let fingerprint = Self(digest: Data(hash.finalize()))
            if info.st_mode & S_IFMT == S_IFDIR { tree[relative] = fingerprint }
            return fingerprint
        }
        let fingerprint = try visit(root, relative: "")
        tree[""] = fingerprint
        return tree
    }
}
