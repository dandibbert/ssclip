import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }
}

enum Theme {
    static let accent = Color(hex: 0x88F1F7)
    static let controlFill = Color(
        light: Color(hex: 0x63DDEA),
        dark: Color(hex: 0x4FD8E8)
    )
    static let onControl = Color(hex: 0x0E2A33)
    static let accentDeep = Color(hex: 0x2BB8CC)
    static let pink = Color(hex: 0xE9A9B3)
    static let pinkDeep = Color(
        light: Color(hex: 0xD96B87),
        dark: Color(hex: 0xE58CA0)
    )
    static let kindText = Color(hex: 0x2BB8CC)
    static let kindImage = Color(hex: 0xE0899B)
    static let kindFiles = Color(hex: 0xA78BDB)
    static let settingsGeneralIcon = Color(hex: 0x75757B)
    static let settingsShortcutIcon = Color(hex: 0x35B6CC)
    static let settingsFolderIcon = Color(hex: 0xDE8CA0)
    static let danger = Color(
        light: Color(hex: 0xFF453A),
        dark: Color(hex: 0xFF6B5E)
    )

    static let panelTint = LinearGradient(
        colors: [
            Color(
                light: Color(hex: 0xBFF6FA, opacity: 0.60),
                dark: Color(hex: 0x88F1F7, opacity: 0.10)
            ),
            Color(
                light: Color(hex: 0xFAE4EA, opacity: 0.50),
                dark: Color(hex: 0xE9A9B3, opacity: 0.07)
            ),
            Color(
                light: Color(hex: 0xE9E7F8, opacity: 0.45),
                dark: Color(hex: 0xA78BDB, opacity: 0.06)
            )
        ],
        startPoint: UnitPoint(x: 0.15, y: 0),
        endPoint: UnitPoint(x: 0.85, y: 1)
    )

    static let rowSelection = LinearGradient(
        colors: [
            Color(
                light: Color(hex: 0x4FD8E8, opacity: 0.42),
                dark: Color(hex: 0x4FD8E8, opacity: 0.30)
            ),
            Color(
                light: Color(hex: 0xE9A9B3, opacity: 0.38),
                dark: Color(hex: 0xE9A9B3, opacity: 0.26)
            )
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let rowSelectionStroke = Color(
        light: Color(hex: 0x4FD8E8, opacity: 0.32),
        dark: Color(hex: 0x88F1F7, opacity: 0.28)
    )

    static let appBadge = LinearGradient(
        colors: [accent, pink],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let emptyIcon = LinearGradient(
        colors: [
            Color(hex: 0x88F1F7, opacity: 0.22),
            Color(hex: 0xE9A9B3, opacity: 0.20)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let subtleSurface = Color(
        light: .white.opacity(0.50),
        dark: .white.opacity(0.07)
    )
    static let raisedSurface = Color(
        light: .white.opacity(0.72),
        dark: .white.opacity(0.055)
    )
    static let surfaceStroke = Color(
        light: .white.opacity(0.60),
        dark: .white.opacity(0.06)
    )

    static func kindColor(_ kind: ClipboardItemKind) -> Color {
        switch kind {
        case .text: kindText
        case .image: kindImage
        case .files: kindFiles
        }
    }
}
