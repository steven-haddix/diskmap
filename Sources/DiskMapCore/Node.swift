import Synchronization

/// One entry in the scanned tree. Directories hold their children; files below
/// `DiskScanner.individualFileThreshold` are rolled up into a single `.smallFiles`
/// child per directory so millions of tiny files don't each cost a node.
public final class Node: Identifiable, @unchecked Sendable {
    public enum Kind: Sendable { case directory, file, smallFiles }

    public let name: String
    public unowned let parent: Node?
    public let kind: Kind
    /// Allocated bytes on disk, including everything below this node.
    public let bytes = Atomic<Int64>(0)
    /// Number of files rolled into a `.smallFiles` node (0 otherwise).
    public let fileCount: Int
    private let _children = Mutex<[Node]>([])

    public init(name: String, parent: Node?, kind: Kind, bytes: Int64 = 0, fileCount: Int = 0) {
        self.name = name
        self.parent = parent
        self.kind = kind
        self.fileCount = fileCount
        self.bytes.store(bytes, ordering: .relaxed)
    }

    public var size: Int64 { bytes.load(ordering: .relaxed) }

    /// Snapshot of the children. Safe to call while a scan is still filling the tree.
    public var children: [Node] { _children.withLock { $0 } }

    public var sortedChildren: [Node] { children.sorted { $0.size > $1.size } }

    func setChildren(_ nodes: [Node]) { _children.withLock { $0 = nodes } }

    /// Full path; the root node's name is the scanned path itself.
    public var path: String {
        guard let parent else { return name }
        let base = parent.path
        return base.hasSuffix("/") ? base + name : base + "/" + name
    }

    public var ancestors: [Node] {
        var result: [Node] = []
        var node = parent
        while let n = node { result.append(n); node = n.parent }
        return result
    }

    public func isDescendant(of other: Node) -> Bool {
        ancestors.contains { $0 === other }
    }

    /// Swap in a freshly rescanned copy of this folder, adjusting every ancestor's total
    /// by the difference. Does nothing if this node is no longer in the tree.
    public func replace(with replacement: Node) {
        guard let parent else { return }
        let found = parent._children.withLock { children in
            guard let index = children.firstIndex(where: { $0 === self }) else { return false }
            children[index] = replacement
            return true
        }
        guard found else { return }
        let delta = replacement.size - size
        var node: Node? = parent
        while let n = node {
            n.bytes.add(delta, ordering: .relaxed)
            node = n.parent
        }
    }

    /// Detach from the tree after the item was removed from disk, keeping every
    /// ancestor's total truthful.
    public func removeFromTree() {
        guard let parent else { return }
        parent._children.withLock { $0.removeAll { $0 === self } }
        let removed = size
        var node: Node? = parent
        while let n = node {
            n.bytes.subtract(removed, ordering: .relaxed)
            node = n.parent
        }
    }
}
