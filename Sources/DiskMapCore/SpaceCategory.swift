import Foundation

/// What kind of space something is, used for coloring. A node takes the category
/// of its nearest matching ancestor, so `~/Code/x/node_modules` and
/// `~/.cache/huggingface` read as the same culprit wherever they live.
public enum SpaceCategory: String, CaseIterable, Sendable {
    case models, developer, code, docker, temp, downloads, media, apps, system, other

    public var label: String {
        switch self {
        case .models: "LLM models"
        case .developer: "Xcode & simulators"
        case .code: "Code & worktrees"
        case .docker: "Docker"
        case .temp: "Temp & Trash"
        case .downloads: "Downloads"
        case .media: "Photos, video, docs"
        case .apps: "Applications"
        case .system: "System & caches"
        case .other: "Other"
        }
    }

    public static func of(_ node: Node) -> SpaceCategory {
        if node.kind == .file, let category = byExtension[(node.name as NSString).pathExtension.lowercased()] {
            return category
        }
        var current: Node? = node
        while let n = current {
            if let category = match(n) { return category }
            current = n.parent
        }
        return .other
    }

    private static let byExtension: [String: SpaceCategory] = [
        "gguf": .models, "safetensors": .models, "ckpt": .models, "pth": .models, "onnx": .models,
    ]

    private static func match(_ node: Node) -> SpaceCategory? {
        // The scan root's name is a full path; match on its last component.
        let name = node.parent == nil ? (node.name as NSString).lastPathComponent : node.name
        switch name {
        case ".ollama", ".lmstudio", "huggingface", "LM Studio":
            return .models
        case "Developer", "CoreSimulator", "DerivedData", "Xcode.app", ".gradle", "Android":
            return .developer
        case "Code", "node_modules", ".venv", "venv", ".git", "worktrees", ".worktrees",
             ".npm", ".bun", ".cargo", ".rustup", ".pnpm-store", "uv", "pip":
            return .code
        case "com.docker.docker", "Docker.app", "OrbStack", ".orbstack", ".docker":
            return .docker
        case ".Trash", ".Trashes":
            return .temp
        case "tmp" where node.parent == nil || node.parent?.name == "private":
            return .temp
        case "folders" where node.parent?.name == "var":
            return .temp
        case "Downloads":
            return .downloads
        case "Pictures", "Movies", "Music", "Documents":
            return .media
        case "Applications":
            return .apps
        case "Library", "System", "Caches":
            return .system
        default:
            return nil
        }
    }
}
