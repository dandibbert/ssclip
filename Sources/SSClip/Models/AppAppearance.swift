import AppKit

enum AppAppearance: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }
}
