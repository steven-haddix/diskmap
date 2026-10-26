import AppKit
import DiskMapCore
import SwiftUI

enum Style {
    static let chartBackground = Color(red: 0.055, green: 0.063, blue: 0.078)

    static func base(_ category: SpaceCategory) -> NSColor {
        let hex: UInt32 = switch category {
        case .models: 0xA55EEA
        case .developer: 0xFF9F43
        case .code: 0x4B7BEC
        case .docker: 0x2BCBBA
        case .temp: 0xFC5C65
        case .downloads: 0x26DE81
        case .media: 0xFED330
        case .apps: 0x45AAF2
        case .system: 0x778CA3
        case .other: 0x8E99AB
        }
        return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                       blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// Category color, getting darker the deeper it sits so nested items stay distinguishable.
    static func fill(_ node: Node, depth: Int) -> Color {
        let color = base(SpaceCategory.of(node))
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let shaded = max(0.32, brightness - CGFloat(depth - 1) * 0.09)
        let tint = node.kind == .smallFiles ? saturation * 0.45 : saturation
        return Color(hue: hue, saturation: tint, brightness: shaded)
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Paths under the Data volume are shown the way Finder shows them.
    static func path(_ node: Node) -> String {
        var path = node.path
        if path.hasPrefix(AppModel.wholeDisk) { path = String(path.dropFirst(AppModel.wholeDisk.count)) }
        if path.isEmpty { path = "/" }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    static func name(_ node: Node) -> String {
        guard node.parent == nil else { return node.name }
        if node.name == AppModel.wholeDisk { return FileManager.default.displayName(atPath: "/") }
        return (node.name as NSString).abbreviatingWithTildeInPath
    }
}
