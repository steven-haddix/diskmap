import AppKit
import DiskMapCore
import Observation

@Observable @MainActor
final class AppModel {
    enum ChartStyle: String, CaseIterable { case sunburst = "Sunburst", treemap = "Treemap" }

    /// The Data volume holds everything you can delete; scanning it rather than `/`
    /// avoids walking the read-only system volume and its firmlinks.
    nonisolated static let wholeDisk = "/System/Volumes/Data"

    var root: Node?
    var focus: Node?
    var chartStyle: ChartStyle = .sunburst
    var hovered: Node?
    var selected: [Node] = []
    var isScanning = false
    var wasStopped = false
    /// Bumped while scanning (and after deletes) so charts redraw from the live tree.
    var revision = 0
    var filesSeen = 0
    var scannedBytes: Int64 = 0
    var elapsed: TimeInterval = 0
    /// Name of the folder being (or last) rescanned on its own; nil for a full scan.
    var rescannedName: String?
    var unreadable: [String] = []
    /// Non-nil while the delete confirmation sheet is up.
    var pendingTrash: [Node]?
    var trashFailures: [String] = []
    var lastTrashed: (count: Int, bytes: Int64)?

    @ObservationIgnored private var scanner: DiskScanner?
    /// The scan (or latest folder rescan) whose hard-link and clone credits match the tree.
    @ObservationIgnored private var ledger: DiskScanner?
    @ObservationIgnored private var sunburstCache: (key: [AnyHashable], arcs: [SunburstArc])?
    @ObservationIgnored private var treemapCache: (key: [AnyHashable], tiles: [TreemapTile])?

    // MARK: Scanning

    func scan(_ path: String) {
        scanner?.cancel()
        let scanner = DiskScanner(path: path)
        root = scanner.root
        focus = scanner.root
        selected = []
        hovered = nil
        unreadable = []
        lastTrashed = nil
        rescannedName = nil
        start(scanner)
    }

    /// Refreshes one folder after it changed outside DiskMap. The old contents stay on
    /// screen until the rescan finishes and is swapped in.
    func rescan(_ folder: Node) {
        guard !isScanning, folder.kind == .directory else { return }
        guard folder.parent != nil, let ledger else { return scan(folder.path) }
        rescannedName = Style.name(folder)
        start(DiskScanner(rescanning: folder, from: ledger))
    }

    private func start(_ scanner: DiskScanner) {
        self.scanner = scanner
        isScanning = true
        wasStopped = false
        let start = Date()

        Task {
            while isScanning && self.scanner === scanner {
                filesSeen = scanner.filesSeen.load(ordering: .relaxed)
                scannedBytes = scanner.root.size
                elapsed = Date().timeIntervalSince(start)
                // A folder rescan isn't in the tree yet, so there's nothing new to draw.
                if scanner.replacing == nil { revision += 1 }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        Thread.detachNewThread {
            scanner.run()
            Task { @MainActor in self.finish(scanner, elapsed: Date().timeIntervalSince(start)) }
        }
    }

    private func finish(_ finished: DiskScanner, elapsed: TimeInterval) {
        guard finished === scanner else { return }
        isScanning = false
        wasStopped = finished.isCancelled
        filesSeen = finished.filesSeen.load(ordering: .relaxed)
        scannedBytes = finished.root.size
        self.elapsed = elapsed
        if let folder = finished.replacing {
            // A stopped rescan is incomplete; keep the old contents rather than splice it in.
            if !finished.isCancelled {
                finished.spliceIntoTree()
                ledger = finished
                let inside = folder.path + "/"
                unreadable = (unreadable.filter { $0 != folder.path && !$0.hasPrefix(inside) } + finished.unreadable).sorted()
                if let focus, focus === folder || focus.isDescendant(of: folder) { self.focus = finished.root }
                selected = []
                hovered = nil
            }
        } else {
            ledger = finished
            unreadable = finished.unreadable.sorted()
        }
        revision += 1
    }

    func stopScan() { scanner?.cancel() }

    func chooseFolderAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { scan(url.path) }
    }

    // MARK: Navigation

    func zoom(into node: Node) {
        guard node.kind == .directory, node !== focus else { return }
        focus = node
        selected = []
        hovered = nil
    }

    func zoomOut() {
        guard let parent = focus?.parent else { return }
        let previous = focus
        focus = parent
        selected = previous.map { [$0] } ?? []
        hovered = nil
    }

    /// Clicking in a chart zooms into folders and selects files.
    func activate(_ node: Node, extendSelection: Bool) {
        switch node.kind {
        case .directory:
            zoom(into: node)
        case .file:
            if extendSelection {
                if selected.contains(where: { $0 === node }) { selected.removeAll { $0 === node } } else { selected.append(node) }
            } else {
                selected = [node]
            }
        case .smallFiles:
            if let parent = node.parent { zoom(into: parent) }
        }
    }

    // MARK: Layout caches (redrawing on hover must not redo layout)

    func sunburstArcs(focus: Node, rings: Int) -> [SunburstArc] {
        let key: [AnyHashable] = [ObjectIdentifier(focus), revision, rings]
        if let cache = sunburstCache, cache.key == key { return cache.arcs }
        let arcs = SunburstLayout.arcs(focus: focus, maxDepth: rings)
        sunburstCache = (key, arcs)
        return arcs
    }

    func treemapTiles(focus: Node, size: CGSize) -> [TreemapTile] {
        let key: [AnyHashable] = [ObjectIdentifier(focus), revision, size.width, size.height]
        if let cache = treemapCache, cache.key == key { return cache.tiles }
        let tiles = TreemapLayout.tiles(focus: focus, in: CGRect(origin: .zero, size: size))
        treemapCache = (key, tiles)
        return tiles
    }

    // MARK: Deleting

    /// Shows the confirmation sheet. Nothing is touched until `confirmTrash()`.
    func requestTrash(_ nodes: [Node]) {
        guard !isScanning else { return }
        let deletable = nodes.filter { $0.kind != .smallFiles && $0.parent != nil }
        // Drop anything already inside another chosen item so it isn't counted twice.
        let outermost = deletable.filter { node in !deletable.contains { $0 !== node && node.isDescendant(of: $0) } }
        guard !outermost.isEmpty else { return }
        pendingTrash = outermost.sorted { $0.size > $1.size }
    }

    func confirmTrash() {
        guard let items = pendingTrash else { return }
        pendingTrash = nil
        var failures: [String] = []
        var bytes: Int64 = 0
        var count = 0
        for node in items {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: node.path), resultingItemURL: nil)
                bytes += node.size
                count += 1
                node.removeFromTree()
                if let focus, focus === node || focus.isDescendant(of: node) { self.focus = node.parent }
            } catch {
                failures.append("\(Style.path(node)): \(error.localizedDescription)")
            }
        }
        selected = []
        hovered = nil
        trashFailures = failures
        lastTrashed = count > 0 ? (count, bytes) : nil
        revision += 1
    }

    func reveal(_ node: Node) {
        let target = node.kind == .smallFiles ? (node.parent ?? node) : node
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target.path)])
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
