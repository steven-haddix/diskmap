import DiskMapCore
import SwiftUI

struct TreemapView: View {
    @Environment(AppModel.self) private var model
    let focus: Node

    var body: some View {
        GeometryReader { geo in
            let tiles = model.treemapTiles(focus: focus, size: geo.size)
            let hovered = model.hovered.map(ObjectIdentifier.init)
            let selected = Set(model.selected.map(ObjectIdentifier.init))

            Canvas { context, _ in
                for tile in tiles {
                    let rect = tile.rect
                    let shape = Path(roundedRect: rect, cornerRadius: min(3, rect.width / 4, rect.height / 4))
                    if tile.isLeaf {
                        context.fill(shape, with: .color(Style.fill(tile.node, depth: tile.depth)))
                        // Cushion shading: light from the top-left so each tile reads as its own lump.
                        context.fill(shape, with: .radialGradient(
                            Gradient(colors: [.white.opacity(0.28), .black.opacity(0.32)]),
                            center: CGPoint(x: rect.minX + rect.width * 0.35, y: rect.minY + rect.height * 0.3),
                            startRadius: 0, endRadius: max(rect.width, rect.height) * 0.85))
                        if rect.width > 54 && rect.height > 26 {
                            label(context, tile.node, in: rect.insetBy(dx: 4, dy: 3), color: .black.opacity(0.78))
                        }
                    } else {
                        context.fill(shape, with: .color(Style.fill(tile.node, depth: tile.depth).opacity(0.35)))
                        if tile.hasHeader {
                            let header = CGRect(x: rect.minX + 4, y: rect.minY + 1, width: rect.width - 8, height: TreemapLayout.headerHeight - 2)
                            label(context, tile.node, in: header, color: .white.opacity(0.85), singleLine: true)
                        }
                    }
                    let id = ObjectIdentifier(tile.node)
                    if selected.contains(id) {
                        context.stroke(shape, with: .color(.white), lineWidth: 2)
                    } else if id == hovered {
                        context.stroke(shape, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let hit = Self.hit(point, tiles)
                    if hit !== model.hovered { model.hovered = hit }
                case .ended:
                    model.hovered = nil
                }
            }
            .gesture(SpatialTapGesture().modifiers(.command).onEnded { value in
                if let node = Self.hit(value.location, tiles) { model.activate(node, extendSelection: true) }
            })
            .onTapGesture { point in
                if let node = Self.hit(point, tiles) { model.activate(node, extendSelection: false) }
            }
            .contextMenu { NodeMenu(node: model.hovered) }
        }
    }

    private func label(_ context: GraphicsContext, _ node: Node, in rect: CGRect, color: Color, singleLine: Bool = false) {
        var layer = context
        layer.clip(to: Path(rect))
        let text = singleLine
            ? Text("\(node.name)  ").font(.system(size: 10, weight: .semibold)) + Text(Style.size(node.size)).font(.system(size: 10))
            : Text("\(node.name)\n").font(.system(size: 10, weight: .semibold)) + Text(Style.size(node.size)).font(.system(size: 10))
        layer.draw(text.foregroundStyle(color), in: rect)
    }

    /// Deepest tile under the point; children are laid out after their parents.
    static func hit(_ point: CGPoint, _ tiles: [TreemapTile]) -> Node? {
        tiles.last { $0.rect.contains(point) }?.node
    }
}
