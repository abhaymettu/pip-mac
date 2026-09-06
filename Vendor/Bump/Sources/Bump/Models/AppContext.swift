import Foundation

/// Per-app overrides: when this app is frontmost, these gesture→action mappings
/// take precedence over the global ones (this is the "context-aware gestures"
/// feature). Only gestures present here override; others fall back to global.
struct AppContext: Codable, Hashable, Identifiable {
    var bundleID: String
    var name: String
    var mapping: [BumpGesture: ActionConfig] = [:]

    var id: String { bundleID }
}
