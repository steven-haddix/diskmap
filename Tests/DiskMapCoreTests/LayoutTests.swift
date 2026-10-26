import CoreGraphics
import Testing
@testable import DiskMapCore

/// The whole point of the picture is that visual size = disk size; a layout bug
/// that shrinks or overlaps tiles would point you at the wrong thing to delete.
@Suite struct LayoutTests {
    /// root (100) -> big dir (60: 40 + 20), file 25, file 10, file 5
    private func sampleTree() -> Node {
        let root = Node(name: "/disk", parent: nil, kind: .directory, bytes: 100)
        let big = Node(name: "big", parent: root, kind: .directory, bytes: 60)
        big.setChildren([
            Node(name: "a", parent: big, kind: .file, bytes: 40),
            Node(name: "b", parent: big, kind: .file, bytes: 20),
        ])
        root.setChildren([
            big,
            Node(name: "c", parent: root, kind: .file, bytes: 25),
            Node(name: "d", parent: root, kind: .file, bytes: 10),
            Node(name: "e", parent: root, kind: .file, bytes: 5),
        ])
        return root
    }

    @Test func treemapAreasAreProportionalToSizeAndStayInBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let top = TreemapLayout.tiles(focus: sampleTree(), in: bounds).filter { $0.depth == 1 }

        #expect(top.count == 4)
        for tile in top {
            let share = Double(tile.rect.width * tile.rect.height) / Double(bounds.width * bounds.height)
            #expect(abs(share - Double(tile.node.size) / 100) < 0.001, "\(tile.node.name)")
            #expect(bounds.insetBy(dx: -0.001, dy: -0.001).contains(tile.rect))
        }
        for (i, a) in top.enumerated() {
            for b in top[(i + 1)...] {
                let overlap = a.rect.intersection(b.rect)
                #expect(overlap.isNull || overlap.width * overlap.height < 0.001)
            }
        }
    }

    @Test func sunburstSlicesSplitTheirParentBySize() {
        let arcs = SunburstLayout.arcs(focus: sampleTree(), maxDepth: 4)
        let ring1 = arcs.filter { $0.depth == 1 }
        let ring2 = arcs.filter { $0.depth == 2 }

        #expect(abs(ring1.reduce(0) { $0 + $1.endAngle - $1.startAngle } - 2 * .pi) < 1e-9)
        let big = ring1.first { $0.node.name == "big" }!
        #expect(abs((big.endAngle - big.startAngle) - 2 * .pi * 0.6) < 1e-9)
        // Children sit inside their parent's slice, split 40:20.
        let a = ring2.first { $0.node.name == "a" }!
        #expect(a.startAngle == big.startAngle)
        #expect(abs((a.endAngle - a.startAngle) - (big.endAngle - big.startAngle) * 2 / 3) < 1e-9)
    }
}
