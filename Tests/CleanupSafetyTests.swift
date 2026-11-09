import XCTest
import Darwin
@testable import CleanupCore

final class CleanupSafetyTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-safety-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Only remove disposable fixtures created by this test, never configured cleanup paths.
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    private func rule(_ path: String) -> CleanupRule {
        CleanupRule(id: "test", role: "programmer", title: "Test", path: path, summary: "Test", impact: "Test", risk: .low, category: "Xcode", subfolderDescriptions: nil)
    }

    func testPathGrammarAndAllowlist() {
        XCTAssertNotNil(rule("$HOME/Library/Developer/Xcode/DerivedData").resolvedPath)
        for path in ["/private/tmp", "$HOME/", "~/Library/Caches/pip", "$HOME/Library/Caches", "$HOME/Library/Caches/pip/../secret", "$HOME/Library/Caches/pip/./x", "$HOME/Library/Caches/pip//x", "$HOME/Library/Caches/pip/*", "$HOME/Library/Caches/pip/$USER", "$HOME/Library/Caches/pip-other"] {
            XCTAssertNil(rule(path).resolvedPath, "Rejected malformed or unapproved path")
        }
    }
    func testSelectingChildRemovesParentAndKeepsOtherRules() {
        let parent = CleanupSelection(ruleID: "a", subfolderPath: nil)
        let child = CleanupSelection(ruleID: "a", subfolderPath: "one")
        let other = CleanupSelection(ruleID: "b", subfolderPath: nil)
        XCTAssertEqual(CleanupSelection.toggling(child, in: [parent, other]), [child, other])
    }
    func testSelectingAncestorRemovesOnlyDescendants() {
        let child = CleanupSelection(ruleID: "a", subfolderPath: "one/two")
        let sibling = CleanupSelection(ruleID: "a", subfolderPath: "one-other")
        let ancestor = CleanupSelection(ruleID: "a", subfolderPath: "one")
        XCTAssertEqual(CleanupSelection.toggling(ancestor, in: [child, sibling]), [ancestor, sibling])
        XCTAssertEqual(CleanupSelection.toggling(ancestor, in: [ancestor]), [])
        XCTAssertEqual(CleanupSelection.toggling(.init(ruleID: "a", subfolderPath: nil), in: [child, sibling]), [.init(ruleID: "a", subfolderPath: nil)])
    }
    func testEmptyDirectoryIsZero() throws {
        try fixture { root in
            let result = try CleanupStore.directoryBreakdown(at: root, descriptions: [:])
            XCTAssertEqual(result.size, 0); XCTAssertTrue(result.subfolders.isEmpty)
        }
    }
    func testMissingDirectoryIsFailureNotZero() throws {
        try fixture { root in
            XCTAssertThrowsError(try CleanupStore.directoryBreakdown(at: root.appendingPathComponent("missing"), descriptions: [:]))
        }
    }
    func testUnreadableDescendantFailsWholeScan() throws {
        guard getuid() != 0 else { throw XCTSkip("Permission test requires a non-root account") }
        try fixture { root in
            let locked = root.appendingPathComponent("locked")
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
            XCTAssertThrowsError(try CleanupStore.directoryBreakdown(at: root, descriptions: [:]))
            XCTAssertThrowsError(try DirectoryFingerprint.capture(root))
        }
    }
    func testCancellationRejectsScanAndFingerprint() throws {
        try fixture { root in
            let control = OperationControl(); control.cancel()
            XCTAssertThrowsError(try CleanupStore.directoryBreakdown(at: root, descriptions: [:], control: control)) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertThrowsError(try DirectoryFingerprint.capture(root, control: control)) { XCTAssertTrue($0 is CancellationError) }
        }
    }
    func testFingerprintDetectsSameSizeRewriteAndHiddenChanges() throws {
        try fixture { root in
            let file = root.appendingPathComponent("data")
            try Data("aaaa".utf8).write(to: file)
            let before = try DirectoryFingerprint.capture(root)
            Thread.sleep(forTimeInterval: 0.01)
            try Data("bbbb".utf8).write(to: file)
            XCTAssertNotEqual(before, try DirectoryFingerprint.capture(root))
            let after = try DirectoryFingerprint.capture(root)
            try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden"))
            XCTAssertNotEqual(after, try DirectoryFingerprint.capture(root))
        }
    }
    func testFingerprintDetectsRenameAndRemoval() throws {
        try fixture { root in
            let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
            try Data([1]).write(to: a)
            let before = try DirectoryFingerprint.capture(root)
            try FileManager.default.moveItem(at: a, to: b)
            XCTAssertNotEqual(before, try DirectoryFingerprint.capture(root))
            let renamed = try DirectoryFingerprint.capture(root)
            try FileManager.default.removeItem(at: b)
            XCTAssertNotEqual(renamed, try DirectoryFingerprint.capture(root))
        }
    }
    func testStaleProposalIsRejectedWithoutChangingFiles() throws {
        try fixture { root in
            let file = root.appendingPathComponent("output")
            try Data([1]).write(to: file)
            let expected = try DirectoryFingerprint.capture(root)
            XCTAssertNoThrow(try DirectoryFingerprint.requireUnchanged(root, expected: expected))
            try Data([1, 2]).write(to: file)
            XCTAssertThrowsError(try DirectoryFingerprint.requireUnchanged(root, expected: expected))
            XCTAssertEqual(try Data(contentsOf: file), Data([1, 2]))
        }
    }
    func testSubtreeFingerprintMatchesIndependentCapture() throws {
        try fixture { root in
            let child = root.appendingPathComponent("child")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try Data([1, 2]).write(to: child.appendingPathComponent("file"))
            let tree = try DirectoryFingerprint.captureTree(root)
            XCTAssertEqual(tree["child"], try DirectoryFingerprint.capture(child))
            XCTAssertEqual(tree[""], try DirectoryFingerprint.capture(root))
        }
    }
    func testSymlinkIsNotFollowedAndCannotBeSelectedAsTarget() throws {
        try fixture { root in
            let source = root.appendingPathComponent("source"), outside = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let link = source.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            let before = try DirectoryFingerprint.capture(source)
            try Data([42]).write(to: outside.appendingPathComponent("private-file"))
            XCTAssertEqual(before, try DirectoryFingerprint.capture(source))
            XCTAssertEqual(try CleanupStore.directoryBreakdown(at: source, descriptions: [:]).size, 0)
            XCTAssertThrowsError(try CleanupStore.rejectSymbolicLinksAlongPath(from: source, to: link))
            XCTAssertThrowsError(try CleanupStore.rejectSymbolicLinksAlongPath(from: link, to: link))
            XCTAssertThrowsError(try CleanupStore.rejectSymbolicLinksAlongPath(from: source, to: outside))
        }
    }
}

final class CommandRunnerTests: XCTestCase {
    private func python(_ script: String, timeout: TimeInterval = 5, control: OperationControl? = nil) throws -> CommandResult {
        try CommandRunner.run(executable: "/usr/bin/python3", arguments: ["-c", script], timeout: timeout, control: control)
    }
    func testBothPipesDrainWithoutDeadlock() throws {
        let result = try python("import sys\nsys.stderr.write('e' * 300000)\nsys.stderr.flush()\nsys.stdout.write('o' * 300000)")
        XCTAssertEqual(result.status, 0); XCTAssertEqual(result.output.count, 300000); XCTAssertEqual(result.error.count, 300000)
    }
    func testExitStatusPreserved() throws {
        XCTAssertEqual(try python("import sys; sys.exit(7)").status, 7)
    }
    func testTimeoutReturnsPromptly() throws {
        let start = Date()
        XCTAssertThrowsError(try python("import time; time.sleep(30)", timeout: 0.15)) { XCTAssertTrue($0 is OperationFailure) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }
    func testTimeoutEscalatesWhenTermIgnored() throws {
        let start = Date()
        XCTAssertThrowsError(try python("import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)", timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
    func testRunningCommandCanBeCancelled() throws {
        let control = OperationControl()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { control.cancel() }
        XCTAssertThrowsError(try python("import time; time.sleep(30)", control: control)) { XCTAssertTrue($0 is CancellationError) }
    }
    func testOutputProgressIsBoundedAndRedactsHome() throws {
        let control = OperationControl()
        _ = try python("import os; print('x' * 4000); print(os.path.expanduser('~'))", control: control)
        XCTAssertLessThanOrEqual(control.status.count, 2000)
        XCTAssertFalse(control.status.contains(NSHomeDirectory()))
        XCTAssertTrue(control.status.contains("$HOME"))
    }
    func testChildHoldingPipeDoesNotBlockExitedCommand() throws {
        let start = Date()
        _ = try python("import subprocess; subprocess.Popen(['/bin/sleep','2'])")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }
}
