import Darwin
import Foundation
import Testing
@testable import DiskMapCore

/// The sizes DiskMap shows are what you decide to delete by, so they must match
/// what the files really occupy on disk (what `du` reports), not logical length.
@Suite final class DiskScannerTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("diskmap-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relativePath: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    /// Independent oracle: st_blocks of each distinct inode.
    private func allocatedBytes(_ urls: [URL]) -> Int64 {
        var seen = Set<UInt64>()
        var total: Int64 = 0
        for url in urls {
            var info = stat()
            lstat(url.path, &info)
            if seen.insert(info.st_ino).inserted { total += Int64(info.st_blocks) * 512 }
        }
        return total
    }

    private func child(_ node: Node, _ name: String) -> Node? {
        node.children.first { $0.name == name }
    }

    @Test func totalsMatchOnDiskAllocationAndRollUpToEveryAncestor() throws {
        let big = try write("models/big.gguf", bytes: 3 << 20)
        let medium = try write("code/repo/build.bin", bytes: 2 << 20)
        let small = try (0..<10).map { try write("code/repo/src/file\($0).txt", bytes: 4096) }

        let scanner = DiskScanner(path: root.path)
        scanner.run(threads: 4)

        let expected = allocatedBytes([big, medium] + small)
        #expect(scanner.root.size == expected)
        #expect(scanner.unreadable.isEmpty)

        let code = try #require(child(scanner.root, "code"))
        let repo = try #require(child(code, "repo"))
        #expect(repo.size == allocatedBytes([medium] + small))

        // Big files are individually selectable; tiny ones are one rolled-up tile.
        let models = try #require(child(scanner.root, "models"))
        #expect(child(models, "big.gguf")?.kind == .file)
        let src = try #require(child(repo, "src"))
        #expect(src.children.count == 1)
        #expect(src.children.first?.kind == .smallFiles)
        #expect(src.children.first?.fileCount == 10)
    }

    @Test func hardLinkedFileIsCountedOnce() throws {
        // Without this, tools that hard-link caches (uv, pnpm) would look twice as big.
        let original = try write("a/weights.bin", bytes: 4 << 20)
        let linked = root.appendingPathComponent("b/weights-link.bin")
        try FileManager.default.createDirectory(at: linked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: original, to: linked)

        let scanner = DiskScanner(path: root.path)
        scanner.run(threads: 4)

        #expect(scanner.root.size == allocatedBytes([original]))
    }

    @Test func apfsCloneIsCountedOnce() throws {
        // uv, bun and Finder "Duplicate" make copy-on-write clones that share blocks.
        // Counting each in full made a real disk look 132 GB fuller than `df` said,
        // and would promise space that deleting one copy can't free.
        let original = try write("cache/wheel.bin", bytes: 4 << 20)
        let clone = root.appendingPathComponent("venv/wheel.bin")
        try FileManager.default.createDirectory(at: clone.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(clonefile(original.path, clone.path, 0) == 0)

        let scanner = DiskScanner(path: root.path)
        scanner.run(threads: 4)

        #expect(scanner.root.size == allocatedBytes([original]))
    }

    @Test func rescanningOneFolderMatchesAFullScanEvenWithClonesAcrossTheBoundary() throws {
        // Refreshing a folder after changing it outside DiskMap must give the same totals
        // as a full rescan. The trap: a clone family split across the folder boundary
        // (a .venv cloned from ~/.cache/uv) would be counted twice, or not at all, if the
        // rescan forgot which side got the full-size credit.
        let original = try write("a/model.bin", bytes: 4 << 20)
        let clone = root.appendingPathComponent("b/model.bin")
        try FileManager.default.createDirectory(at: clone.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(clonefile(original.path, clone.path, 0) == 0)
        let removed = try write("b/notes.bin", bytes: 2 << 20)
        let removedBytes = allocatedBytes([removed])

        let scanner = DiskScanner(path: root.path)
        scanner.run(threads: 4)

        // Change b/ behind DiskMap's back.
        try FileManager.default.removeItem(at: removed)
        let added = try write("b/new.bin", bytes: 3 << 20)

        // Rescanning a then b exercises both cases whichever folder got the credit first.
        // Until b/ is rescanned it still shows its old contents.
        var ledger = scanner
        let expected = ["a": allocatedBytes([original]) + removedBytes, "b": allocatedBytes([original, added])]
        for name in ["a", "b"] {
            let folder = try #require(child(scanner.root, name))
            let rescan = DiskScanner(rescanning: folder, from: ledger)
            rescan.run(threads: 4)
            rescan.spliceIntoTree()
            ledger = rescan

            #expect(child(scanner.root, name) === rescan.root)
            #expect(scanner.root.size == expected[name], "after rescanning \(name)")
        }
    }

    @Test func unreadableFolderIsReportedNotSilentlySkipped() throws {
        _ = try write("locked/secret.bin", bytes: 2 << 20)
        let locked = root.appendingPathComponent("locked")
        chmod(locked.path, 0)
        defer { chmod(locked.path, 0o755) }

        let scanner = DiskScanner(path: root.path)
        scanner.run(threads: 2)

        #expect(scanner.unreadable == [locked.path])
    }

    @Test func removingANodeKeepsAncestorTotalsTruthful() throws {
        let doomed = try write("tmp/agent/run.log", bytes: 2 << 20)
        let kept = try write("tmp/keep.bin", bytes: 2 << 20)

        let scanner = DiskScanner(path: root.path)
        scanner.run(threads: 2)
        let tmp = try #require(child(scanner.root, "tmp"))
        let agent = try #require(child(tmp, "agent"))

        agent.removeFromTree()

        #expect(child(tmp, "agent") == nil)
        #expect(tmp.size == allocatedBytes([kept]))
        #expect(scanner.root.size == allocatedBytes([kept]))
        _ = doomed
    }
}
