import DiskMapCore
import SwiftUI

/// The biggest things in the current folder, as a plain list: easier than a chart
/// for picking exact items to delete.
struct ItemList: View {
    @Environment(AppModel.self) private var model
    let focus: Node
    static let rowLimit = 300

    var body: some View {
        let _ = model.revision
        let children = focus.sortedChildren
        let shown = Array(children.prefix(Self.rowLimit))
        let hidden = children.dropFirst(Self.rowLimit)
        let total = Double(max(focus.size, 1))

        VStack(spacing: 0) {
            HStack {
                Text("Largest in \(Style.name(focus))").font(.headline).lineLimit(1)
                Spacer()
                Text(Style.size(focus.size)).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            List(selection: Binding(
                get: { Set(model.selected.map(\.id)) },
                set: { ids in model.selected = children.filter { ids.contains($0.id) && $0.kind != .smallFiles } }
            )) {
                ForEach(shown) { node in
                    Row(node: node, fraction: Double(node.size) / total)
                        .tag(node.id)
                        .onHover { inside in model.hovered = inside ? node : nil }
                }
                if !hidden.isEmpty {
                    Text("+ \(hidden.count.formatted()) smaller items, \(Style.size(hidden.reduce(0) { $0 + $1.size })) together")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .contextMenu(forSelectionType: Node.ID.self) { ids in
                let nodes = children.filter { ids.contains($0.id) }
                if nodes.count == 1 {
                    NodeMenu(node: nodes[0])
                } else if !nodes.isEmpty {
                    Button("Move \(nodes.count) Items to Trash…", role: .destructive) { model.requestTrash(nodes) }
                        .disabled(model.isScanning)
                }
            } primaryAction: { ids in
                guard let node = children.first(where: { ids.contains($0.id) }) else { return }
                if node.kind == .directory { model.zoom(into: node) } else { model.reveal(node) }
            }

            Divider()
            HStack {
                if model.selected.isEmpty {
                    Text("Click items to select them").foregroundStyle(.secondary)
                } else {
                    Text("\(model.selected.count) selected · \(Style.size(model.selected.reduce(0) { $0 + $1.size }))")
                        .monospacedDigit()
                }
                Spacer()
                Button("Move to Trash…", role: .destructive) { model.requestTrash(model.selected) }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selected.isEmpty || model.isScanning)
                    .help(model.isScanning ? "Wait for the scan to finish" : "Move the selected items to the Trash (⌘⌫)")
            }
            .padding(10)
        }
    }

    private struct Row: View {
        let node: Node
        let fraction: Double

        var body: some View {
            let color = Color(nsColor: Style.base(SpaceCategory.of(node)))
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(color).frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.name).lineLimit(1).truncationMode(.middle)
                    GeometryReader { geo in
                        Capsule().fill(color.opacity(0.85))
                            .frame(width: max(2, geo.size.width * fraction))
                    }
                    .frame(height: 3)
                }
                Text(Style.size(node.size)).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }

        private var icon: String {
            switch node.kind {
            case .directory: "folder.fill"
            case .file: "doc.fill"
            case .smallFiles: "square.grid.3x3.fill"
            }
        }
    }
}
