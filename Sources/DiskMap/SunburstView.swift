import DiskMapCore
import SwiftUI

struct SunburstView: View {
    @Environment(AppModel.self) private var model
    let focus: Node
    static let rings = 6

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = max(40, min(geo.size.width, geo.size.height) / 2 - 16)
            let hole = radius * 0.26
            let ringWidth = (radius - hole) / CGFloat(Self.rings)
            let arcs = model.sunburstArcs(focus: focus, rings: Self.rings)
            let hovered = model.hovered
            let highlighted = hovered.map { Set([ObjectIdentifier($0)] + $0.ancestors.map(ObjectIdentifier.init)) }
            let selected = Set(model.selected.map(ObjectIdentifier.init))

            ZStack {
                Canvas { context, _ in
                    for arc in arcs {
                        let id = ObjectIdentifier(arc.node)
                        let inner = hole + CGFloat(arc.depth - 1) * ringWidth + 0.75
                        let path = Self.sector(center: center, inner: inner, outer: inner + ringWidth - 1.5,
                                               start: arc.startAngle, end: arc.endAngle)
                        var fill = Style.fill(arc.node, depth: arc.depth)
                        if let highlighted, !highlighted.contains(id) { fill = fill.opacity(0.3) }
                        context.fill(path, with: .color(fill))
                        if selected.contains(id) { context.stroke(path, with: .color(.white), lineWidth: 2) }
                    }
                }

                Circle()
                    .fill(Color.white.opacity(hovered == nil ? 0.06 : 0.03))
                    .frame(width: hole * 2 - 6, height: hole * 2 - 6)
                VStack(spacing: 2) {
                    let shown = hovered ?? focus
                    Text(Style.size(shown.size)).font(.system(size: max(13, hole * 0.22), weight: .bold))
                    Text(Style.name(shown)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if hovered == nil && focus.parent != nil {
                        Text("click to go up").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .frame(width: hole * 1.6)
                .multilineTextAlignment(.center)
                .position(center)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let hit = Self.hit(point, center: center, hole: hole, ringWidth: ringWidth, arcs: arcs)
                    if hit !== model.hovered { model.hovered = hit }
                case .ended:
                    model.hovered = nil
                }
            }
            .gesture(SpatialTapGesture().modifiers(.command).onEnded { value in
                if let node = Self.hit(value.location, center: center, hole: hole, ringWidth: ringWidth, arcs: arcs) {
                    model.activate(node, extendSelection: true)
                }
            })
            .onTapGesture { point in
                if hypot(point.x - center.x, point.y - center.y) < hole {
                    model.zoomOut()
                } else if let node = Self.hit(point, center: center, hole: hole, ringWidth: ringWidth, arcs: arcs) {
                    model.activate(node, extendSelection: false)
                }
            }
            .contextMenu { NodeMenu(node: model.hovered) }
        }
    }

    /// Annular sector; angles are clockwise from 12 o'clock.
    static func sector(center: CGPoint, inner: CGFloat, outer: CGFloat, start: Double, end: Double) -> Path {
        // A hairline gap between neighbours, without eating thin slices entirely.
        let gap = min(0.6 / Double(outer), (end - start) * 0.2)
        let a0 = Angle.radians(start + gap - .pi / 2)
        let a1 = Angle.radians(end - gap - .pi / 2)
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: a1, endAngle: a0, clockwise: true)
        path.closeSubpath()
        return path
    }

    static func hit(_ point: CGPoint, center: CGPoint, hole: CGFloat, ringWidth: CGFloat, arcs: [SunburstArc]) -> Node? {
        let dx = point.x - center.x, dy = point.y - center.y
        let distance = hypot(dx, dy)
        guard distance >= hole else { return nil }
        let depth = Int((distance - hole) / ringWidth) + 1
        var angle = atan2(Double(dx), Double(-dy))
        if angle < 0 { angle += 2 * .pi }
        return arcs.first { $0.depth == depth && angle >= $0.startAngle && angle < $0.endAngle }?.node
    }
}

/// Right-click actions shared by the charts and the list.
struct NodeMenu: View {
    @Environment(AppModel.self) private var model
    let node: Node?

    var body: some View {
        if let node {
            Text("\(Style.name(node)) · \(Style.size(node.size))")
            if node.kind == .directory {
                Button("Zoom In") { model.zoom(into: node) }
                Button("Rescan This Folder") { model.rescan(node) }
                    .disabled(model.isScanning)
            }
            Button("Reveal in Finder") { model.reveal(node) }
            if node.kind != .smallFiles && node.parent != nil {
                Divider()
                Button("Move to Trash…", role: .destructive) { model.requestTrash([node]) }
                    .disabled(model.isScanning)
            }
        }
    }
}
