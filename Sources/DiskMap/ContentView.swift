import DiskMapCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if let focus = model.focus {
                VStack(spacing: 0) {
                    Breadcrumb(focus: focus)
                    Divider()
                    HSplitView {
                        chart(focus)
                            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                        ItemList(focus: focus)
                            .frame(minWidth: 280, idealWidth: 360, maxWidth: 520)
                    }
                    Divider()
                    StatusBar()
                }
            } else {
                StartView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.zoomOut() } label: { Label("Up", systemImage: "chevron.up") }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(model.focus?.parent == nil)
                    .help("Up one folder (⌘↑)")
            }
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $model.chartStyle) {
                    ForEach(AppModel.ChartStyle.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .disabled(model.root == nil)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isScanning {
                    Button { model.stopScan() } label: { Label("Stop", systemImage: "stop.fill") }
                }
                Menu {
                    Button("Macintosh HD") { model.scan(AppModel.wholeDisk) }
                    Button("Home Folder") { model.scan(NSHomeDirectory()) }
                    Button("Choose Folder…") { model.chooseFolderAndScan() }
                    if let root = model.root, let focus = model.focus {
                        Divider()
                        Button("Rescan \(Style.name(focus))") { model.rescan(focus) }
                            .keyboardShortcut("r", modifiers: .command)
                            .disabled(model.isScanning)
                        if focus !== root {
                            Button("Rescan Everything (\(Style.name(root)))") { model.scan(root.path) }
                        }
                    }
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
            }
        }
        .sheet(isPresented: Binding(get: { model.pendingTrash != nil }, set: { if !$0 { model.pendingTrash = nil } })) {
            if let items = model.pendingTrash { ConfirmTrashSheet(items: items) }
        }
        .alert("Some items couldn't be moved to the Trash",
               isPresented: Binding(get: { !model.trashFailures.isEmpty }, set: { if !$0 { model.trashFailures = [] } })) {
            Button("OK") { model.trashFailures = [] }
        } message: {
            Text(model.trashFailures.joined(separator: "\n"))
        }
    }

    private func chart(_ focus: Node) -> some View {
        ZStack(alignment: .topLeading) {
            Style.chartBackground
            Group {
                switch model.chartStyle {
                case .sunburst: SunburstView(focus: focus).padding(8)
                case .treemap: TreemapView(focus: focus).padding(EdgeInsets(top: 52, leading: 8, bottom: 56, trailing: 8))
                }
            }
            .id(ObjectIdentifier(focus))
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
            HoverInfo(focus: focus).padding(12)
            Legend().frame(maxHeight: .infinity, alignment: .bottomLeading).padding(12)
        }
        .animation(.easeInOut(duration: 0.22), value: ObjectIdentifier(focus))
    }
}

private struct StartView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 56))
                .foregroundStyle(.linearGradient(colors: [.purple, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text("What should DiskMap look at?").font(.title2.bold())
            HStack(spacing: 14) {
                choice("Macintosh HD", "internaldrive") { model.scan(AppModel.wholeDisk) }
                choice("Home Folder", "house") { model.scan(NSHomeDirectory()) }
                choice("Choose Folder…", "folder") { model.chooseFolderAndScan() }
            }
            Text("Folders macOS protects (Mail, Messages, parts of Library) show as unreadable unless DiskMap has Full Disk Access.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Style.chartBackground)
    }

    private func choice(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 28))
                Text(title).font(.headline)
            }
            .frame(width: 150, height: 110)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

private struct Breadcrumb: View {
    @Environment(AppModel.self) private var model
    let focus: Node

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                let trail = Array(focus.ancestors.reversed()) + [focus]
                ForEach(Array(trail.enumerated()), id: \.offset) { index, node in
                    if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    Button(Style.name(node)) { model.focus = node; model.selected = [] }
                        .buttonStyle(.plain)
                        .foregroundStyle(node === focus ? .primary : .secondary)
                        .fontWeight(node === focus ? .semibold : .regular)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }
}

private struct HoverInfo: View {
    @Environment(AppModel.self) private var model
    let focus: Node

    var body: some View {
        let node = model.hovered ?? focus
        let share = focus.size > 0 ? Double(node.size) / Double(focus.size) : 0
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(Color(nsColor: Style.base(SpaceCategory.of(node)))).frame(width: 8, height: 8)
                Text(Style.name(node)).font(.headline).lineLimit(1)
                Text(Style.size(node.size)).font(.headline).foregroundStyle(.secondary)
                if node !== focus { Text(share.formatted(.percent.precision(.fractionLength(1)))).foregroundStyle(.tertiary) }
            }
            Text(node.kind == .smallFiles ? "\(node.fileCount.formatted()) files under 1 MB in \(Style.path(node.parent ?? node))" : Style.path(node))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 560, alignment: .leading)
        .allowsHitTesting(false)
    }
}

private struct Legend: View {
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(SpaceCategory.allCases.filter { $0 != .other }, id: \.self) { category in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: Style.base(category))).frame(width: 9, height: 9)
                    Text(category.label).lineLimit(1).fixedSize()
                }
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .allowsHitTesting(false)
    }
}

private struct StatusBar: View {
    @Environment(AppModel.self) private var model
    @State private var showUnreadable = false

    var body: some View {
        HStack(spacing: 12) {
            let what = model.rescannedName.map { "Rescanning \($0)" } ?? "Scanning"
            if model.isScanning {
                ProgressView().controlSize(.small)
                Text("\(what)… \(model.filesSeen.formatted()) files · \(Style.size(model.scannedBytes)) · \(Int(model.elapsed))s")
                    .monospacedDigit()
            } else if model.root != nil {
                let done = model.wasStopped ? "Stopped after" : (model.rescannedName.map { "Rescanned \($0):" } ?? "Scanned")
                Text("\(done) \(model.filesSeen.formatted()) files in \(model.elapsed.formatted(.number.precision(.fractionLength(1))))s")
                    .monospacedDigit()
            }
            if !model.unreadable.isEmpty {
                Button("\(model.unreadable.count.formatted()) folders couldn't be read") { showUnreadable = true }
                    .buttonStyle(.link)
                    .popover(isPresented: $showUnreadable) { UnreadableList() }
            }
            Spacer()
            if let last = model.lastTrashed {
                Text("Moved \(last.count) item\(last.count == 1 ? "" : "s") (\(Style.size(last.bytes))) to the Trash. Empty the Trash to free the space.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct UnreadableList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("These folders weren't counted").font(.headline)
            Text("Their sizes are missing from the totals. Most are protected by macOS; granting DiskMap Full Disk Access lets it read them (rescan afterwards). Some are owned by the system and stay unreadable.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(model.unreadable.prefix(1000), id: \.self) { path in
                Text(path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
            }
            .frame(height: 260)
            Button("Open Full Disk Access Settings…") { model.openFullDiskAccessSettings() }
        }
        .padding(16)
        .frame(width: 520)
    }
}

private struct ConfirmTrashSheet: View {
    @Environment(AppModel.self) private var model
    let items: [Node]

    var body: some View {
        let total = items.reduce(0) { $0 + $1.size }
        VStack(alignment: .leading, spacing: 14) {
            Label(items.count == 1 ? "Move this item to the Trash?" : "Move these \(items.count) items to the Trash?", systemImage: "trash")
                .font(.title3.bold())
            Text("\(Style.size(total)) will go to the Trash. You can put it back from there; the space is only freed once you empty the Trash.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(items) { node in
                HStack {
                    Image(systemName: node.kind == .directory ? "folder.fill" : "doc.fill")
                        .foregroundStyle(Color(nsColor: Style.base(SpaceCategory.of(node))))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.name).fontWeight(.semibold).lineLimit(1)
                        Text(Style.path(node)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Text(Style.size(node.size)).monospacedDigit()
                }
            }
            .frame(minHeight: 90, idealHeight: min(CGFloat(items.count) * 44 + 12, 280), maxHeight: 280)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.pendingTrash = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive) { model.confirmTrash() }
                    .tint(.red)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
