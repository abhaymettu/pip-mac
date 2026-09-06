import Foundation

/// A recognized bump gesture: how many taps in quick succession.
enum BumpGesture: String, Codable, CaseIterable, Identifiable, Hashable {
    case single
    case double
    case triple

    var id: String { rawValue }

    var tapCount: Int {
        switch self {
        case .single: return 1
        case .double: return 2
        case .triple: return 3
        }
    }

    var label: String {
        switch self {
        case .single: return "Single Bump"
        case .double: return "Double Bump"
        case .triple: return "Triple Bump"
        }
    }

    var symbol: String {
        switch self {
        case .single: return "1.circle.fill"
        case .double: return "2.circle.fill"
        case .triple: return "3.circle.fill"
        }
    }
}
