import Darwin
import Foundation
import Synchronization

/// Walks a directory tree on all cores using `getattrlistbulk(2)`, which returns
/// name, type, inode and allocated size for many entries per syscall.
///
/// - Sizes are allocated bytes (what the file really occupies), like `du`.
/// - Hard-linked files are counted once. So are APFS clones: the first copy seen
///   counts in full, later copies only count their private (unshared) bytes.
/// - Mount points are skipped, so a scan never wanders onto another volume.
/// - Directories that can't be opened are recorded in `unreadable`, never silently dropped.
public final class DiskScanner: @unchecked Sendable {
    /// Files at least this big get their own node; smaller ones are rolled up per directory.
    public static let individualFileThreshold: Int64 = 1 << 20

    public let root: Node
    /// The folder a rescan will replace; nil for a full scan.
    public let replacing: Node?
    public let filesSeen = Atomic<Int>(0)
    private let _unreadable = Mutex<[String]>([])
    private let cancelled = Atomic<Bool>(false)
    // Which directory got the full-size credit for each hard-linked inode and clone
    // family, so a later rescan of one folder can keep credits that live outside it.
    private let linkOwners: Mutex<[UInt64: Node]>
    private let cloneOwners: Mutex<[UInt64: Node]>

    // Work queue of directories still to list. `active` counts directories being listed right now.
    private let queueLock = NSCondition()
    private var pending: [(node: Node, path: String)]
    private var active = 0

    private static let bufferSize = 256 * 1024

    public init(path: String) {
        root = Node(name: path, parent: nil, kind: .directory)
        replacing = nil
        pending = [(root, path)]
        linkOwners = Mutex([:])
        cloneOwners = Mutex([:])
    }

    /// Rescans one folder from an earlier scan (`previous`, or the last rescan after it)
    /// into a fresh, unattached node; `spliceIntoTree()` swaps it in once done.
    public init(rescanning folder: Node, from previous: DiskScanner) {
        root = Node(name: folder.name, parent: folder.parent, kind: .directory)
        replacing = folder
        pending = [(root, folder.path)]
        let outside = { (owner: Node) in owner !== folder && !owner.isDescendant(of: folder) }
        linkOwners = Mutex(previous.linkOwners.withLock { $0.filter { outside($0.value) } })
        cloneOwners = Mutex(previous.cloneOwners.withLock { $0.filter { outside($0.value) } })
    }

    /// Puts a finished rescan into the tree in place of the folder it replaces and
    /// corrects every ancestor's total.
    public func spliceIntoTree() {
        replacing?.replace(with: root)
    }

    public var unreadable: [String] { _unreadable.withLock { $0 } }

    public func cancel() {
        cancelled.store(true, ordering: .relaxed)
        queueLock.lock()
        queueLock.broadcast()
        queueLock.unlock()
    }

    public var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    /// Scans to completion (or cancellation). Blocks the calling thread, which
    /// also does work alongside the extra worker threads.
    public func run(threads: Int = ProcessInfo.processInfo.activeProcessorCount) {
        let group = DispatchGroup()
        for _ in 1..<max(threads, 1) {
            group.enter()
            let thread = Thread { [self] in work(); group.leave() }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        work()
        group.wait()
    }

    private func work() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        while let job = nextJob() {
            let subdirectories = list(job.node, path: job.path, buffer: buffer)
            finishJob(adding: subdirectories)
        }
    }

    private func nextJob() -> (node: Node, path: String)? {
        queueLock.lock()
        defer { queueLock.unlock() }
        while pending.isEmpty {
            if active == 0 || isCancelled { return nil }
            queueLock.wait()
        }
        if isCancelled { return nil }
        active += 1
        return pending.removeLast()
    }

    private func finishJob(adding subdirectories: [(node: Node, path: String)]) {
        queueLock.lock()
        pending.append(contentsOf: subdirectories)
        active -= 1
        if !subdirectories.isEmpty || (pending.isEmpty && active == 0) {
            queueLock.broadcast()
        }
        queueLock.unlock()
    }

    /// Lists one directory, publishes its children, adds its file bytes to every
    /// ancestor, and returns the subdirectories still to be listed.
    private func list(_ directory: Node, path: String, buffer: UnsafeMutableRawPointer) -> [(node: Node, path: String)] {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            _unreadable.withLock { $0.append(path) }
            return []
        }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FILEID)
        request.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        request.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        // With FSOPT_ATTR_CMN_EXTENDED the fork group carries the extended common attributes.
        // PRIVATESIZE is deliberately not requested here: computing it for every file
        // tripled scan time, and it's only needed for repeat sightings of a clone.
        request.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID) | attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)

        let prefix = path.hasSuffix("/") ? path : path + "/"
        var children: [Node] = []
        var subdirectories: [(node: Node, path: String)] = []
        var fileBytes: Int64 = 0
        var smallBytes: Int64 = 0
        var smallCount = 0
        var filesListed = 0

        while !isCancelled {
            let count = getattrlistbulk(fd, &request, buffer, Self.bufferSize, UInt64(FSOPT_ATTR_CMN_EXTENDED))
            if count < 0 {
                _unreadable.withLock { $0.append(path) }
                break
            }
            if count == 0 { break }

            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                var field = entry + MemoryLayout<UInt32>.size
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size

                // Order follows getattrlist(2): ERROR sits right after RETURNED_ATTRS,
                // then common attributes by bit order, then dir, then file attributes.
                if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
                    let error = field.loadUnaligned(as: UInt32.self)
                    field += MemoryLayout<UInt32>.size
                    if error != 0 { continue }
                }
                var name = ""
                if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
                    let reference = field.loadUnaligned(as: attrreference_t.self)
                    let start = (field + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
                    name = String(cString: start)
                    field += MemoryLayout<attrreference_t>.size
                }
                var objectType: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                    objectType = field.loadUnaligned(as: UInt32.self)
                    field += MemoryLayout<UInt32>.size
                }
                var fileID: UInt64 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 {
                    fileID = field.loadUnaligned(as: UInt64.self)
                    field += MemoryLayout<UInt64>.size
                }
                var mountStatus: UInt32 = 0
                if returned.dirattr & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0 {
                    mountStatus = field.loadUnaligned(as: UInt32.self)
                    field += MemoryLayout<UInt32>.size
                }
                var linkCount: UInt32 = 1
                if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
                    linkCount = field.loadUnaligned(as: UInt32.self)
                    field += MemoryLayout<UInt32>.size
                }
                var allocated: Int64 = 0
                if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
                    allocated = field.loadUnaligned(as: Int64.self)
                    field += MemoryLayout<Int64>.size
                }
                var cloneID: UInt64 = 0
                if returned.forkattr & attrgroup_t(ATTR_CMNEXT_CLONEID) != 0 {
                    cloneID = field.loadUnaligned(as: UInt64.self)
                    field += MemoryLayout<UInt64>.size
                }
                var extendedFlags: UInt64 = 0
                if returned.forkattr & attrgroup_t(ATTR_CMNEXT_EXT_FLAGS) != 0 {
                    extendedFlags = field.loadUnaligned(as: UInt64.self)
                    field += MemoryLayout<UInt64>.size
                }

                if objectType == VDIR.rawValue {
                    if mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0 { continue }
                    let child = Node(name: name, parent: directory, kind: .directory)
                    children.append(child)
                    subdirectories.append((child, prefix + name))
                    continue
                }

                if linkCount > 1 {
                    if !Self.claim(fileID, for: directory, in: linkOwners) { continue }
                }
                if extendedFlags & UInt64(EF_MAY_SHARE_BLOCKS) != 0 && cloneID != 0 {
                    let firstSighting = Self.claim(cloneID, for: directory, in: cloneOwners)
                    if !firstSighting {
                        allocated = extendedFlags & UInt64(EF_SHARES_ALL_BLOCKS) != 0
                            ? 0 : privateSize(of: name, in: fd) ?? allocated
                    }
                }
                filesListed += 1
                fileBytes += allocated
                if allocated >= Self.individualFileThreshold {
                    children.append(Node(name: name, parent: directory, kind: .file, bytes: allocated))
                } else {
                    smallBytes += allocated
                    smallCount += 1
                }
            }
        }

        if smallCount > 0 {
            let label = smallCount == 1 ? "1 small file" : "\(smallCount) small files"
            children.append(Node(name: label, parent: directory, kind: .smallFiles, bytes: smallBytes, fileCount: smallCount))
        }
        directory.setChildren(children)
        filesSeen.add(filesListed, ordering: .relaxed)

        // Stop at the scan root: a rescan's root points at the real parent, whose
        // totals are only corrected when the finished rescan is spliced in.
        var node: Node? = directory
        while let n = node {
            n.bytes.add(fileBytes, ordering: .relaxed)
            node = n === root ? nil : n.parent
        }
        return subdirectories
    }

    /// True if this is the first sighting, which then gets the full-size credit.
    private static func claim(_ id: UInt64, for directory: Node, in owners: borrowing Mutex<[UInt64: Node]>) -> Bool {
        owners.withLock { owners in
            guard owners[id] == nil else { return false }
            owners[id] = directory
            return true
        }
    }

    /// Bytes that deleting this file alone would free (not shared with a clone or snapshot).
    private func privateSize(of name: String, in directory: Int32) -> Int64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        return withUnsafeTemporaryAllocation(byteCount: 16, alignment: 8) { buffer in
            let options = UInt(FSOPT_ATTR_CMN_EXTENDED) | UInt(FSOPT_NOFOLLOW)
            guard getattrlistat(directory, name, &request, buffer.baseAddress, buffer.count, options) == 0 else { return nil }
            // Layout: u32 total length, then the off_t.
            return buffer.baseAddress!.loadUnaligned(fromByteOffset: 4, as: Int64.self)
        }
    }
}
