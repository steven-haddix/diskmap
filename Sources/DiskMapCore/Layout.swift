import CoreGraphics

/// Children's sizes can briefly run ahead of their parent's total while a scan is
/// still adding bytes, so layouts divide by whichever is larger.
private func layoutTotal(_ node: Node, _ children: [Node]) -> Double {
    Double(max(node.size, children.reduce(0) { $0 + $1.size }))
}

public struct SunburstArc: Sendable {
    public let node: Node
    /// 1 is the ring right outside the center.
    public let depth: Int
    /// Radians, clockwise from 12 o'clock.
    public let startAngle: Double
    public let endAngle: Double
}

public enum SunburstLayout {
    /// Arcs for everything under `focus` up to `maxDepth` rings. Slices thinner than
    /// `minAngle` are dropped; they'd be invisible anyway.
    public static func arcs(focus: Node, maxDepth: Int, minAngle: Double = 0.004) -> [SunburstArc] {
        var result: [SunburstArc] = []
        func visit(_ node: Node, depth: Int, start: Double, span: Double) {
            let children = node.sortedChildren
            let total = layoutTotal(node, children)
            guard total > 0 else { return }
            var angle = start
            for child in children {
                let childSpan = span * Double(child.size) / total
                if childSpan < minAngle { break }
                result.append(SunburstArc(node: child, depth: depth, startAngle: angle, endAngle: angle + childSpan))
                if child.kind == .directory && depth < maxDepth {
                    visit(child, depth: depth + 1, start: angle, span: childSpan)
                }
                angle += childSpan
            }
        }
        visit(focus, depth: 1, start: 0, span: 2 * .pi)
        return result
    }
}

public struct TreemapTile: Sendable {
    public let node: Node
    public let rect: CGRect
    public let depth: Int
    /// Leaves are drawn as filled tiles; non-leaves are frames around their children.
    public let isLeaf: Bool
    public let hasHeader: Bool
}

public enum TreemapLayout {
    public static let headerHeight: CGFloat = 16
    static let padding: CGFloat = 2

    /// Nested squarified treemap of `focus`. Tiles smaller than `minSide` are skipped.
    public static func tiles(focus: Node, in bounds: CGRect, maxDepth: Int = 10, minSide: CGFloat = 3) -> [TreemapTile] {
        var result: [TreemapTile] = []
        func visit(_ node: Node, rect: CGRect, depth: Int) {
            let children = node.sortedChildren.filter { $0.size > 0 }
            let rects = squarify(children.map { Double($0.size) }, total: layoutTotal(node, children), in: rect)
            for (child, r) in zip(children, rects) {
                if r.width < minSide || r.height < minSide { continue }
                let nests = child.kind == .directory && depth < maxDepth && !child.children.isEmpty
                    && r.width > 4 * padding + 6 && r.height > 4 * padding + 6
                let hasHeader = nests && r.width > 60 && r.height > headerHeight * 3
                result.append(TreemapTile(node: child, rect: r, depth: depth, isLeaf: !nests, hasHeader: hasHeader))
                if nests {
                    let top = hasHeader ? headerHeight : padding
                    let inner = CGRect(x: r.minX + padding, y: r.minY + top,
                                       width: r.width - 2 * padding, height: r.height - top - padding)
                    visit(child, rect: inner, depth: depth + 1)
                }
            }
        }
        visit(focus, rect: bounds, depth: 1)
        return result
    }

    /// Squarified layout (Bruls, Huizing, van Wijk). `values` must be sorted largest first.
    static func squarify(_ values: [Double], total: Double, in rect: CGRect) -> [CGRect] {
        guard total > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var rects: [CGRect] = []
        rects.reserveCapacity(areas.count)
        var remaining = rect
        var start = 0

        // Worst aspect ratio in a row; with descending input, max is first and min is last.
        func worst(_ first: Int, _ last: Int, _ sum: Double, _ side: Double) -> Double {
            let s2 = sum * sum, w2 = side * side
            return max(w2 * areas[first] / s2, s2 / (w2 * areas[last]))
        }

        while start < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            guard side > 0 else {
                rects.append(contentsOf: repeatElement(.zero, count: areas.count - start))
                break
            }
            var end = start
            var sum = areas[start]
            var best = worst(start, end, sum, side)
            while end + 1 < areas.count {
                let candidate = worst(start, end + 1, sum + areas[end + 1], side)
                if candidate > best { break }
                end += 1
                sum += areas[end]
                best = candidate
            }

            let thickness = sum / side
            if remaining.width >= remaining.height {
                var y = Double(remaining.minY)
                for i in start...end {
                    let height = areas[i] / thickness
                    rects.append(CGRect(x: Double(remaining.minX), y: y, width: thickness, height: height))
                    y += height
                }
                remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY,
                                   width: max(0, remaining.width - thickness), height: remaining.height)
            } else {
                var x = Double(remaining.minX)
                for i in start...end {
                    let width = areas[i] / thickness
                    rects.append(CGRect(x: x, y: Double(remaining.minY), width: width, height: thickness))
                    x += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness,
                                   width: remaining.width, height: max(0, remaining.height - thickness))
            }
            start = end + 1
        }
        return rects
    }
}
