import Foundation

/// The 7 standardized lifecycle stages of the appitool flow pipeline.
enum FlowStage: String, CaseIterable, Sendable, CustomStringConvertible {
    case setup
    case prebuild
    case build
    case postbuild
    case prerelease
    case release
    case postrelease

    var description: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .setup: return "Setup & Environment"
        case .prebuild: return "Pre-Build & Versioning"
        case .build: return "Build Compilation"
        case .postbuild: return "Post-Build"
        case .prerelease: return "Pre-Release"
        case .release: return "Release & Store Upload"
        case .postrelease: return "Post-Release & Notifications"
        }
    }

    var emoji: String {
        switch self {
        case .setup: return "🔍"
        case .prebuild: return "🔧"
        case .build: return "🔨"
        case .postbuild: return "📦"
        case .prerelease: return "📝"
        case .release: return "🚀"
        case .postrelease: return "📣"
        }
    }
}
