import AppKit
import Carbon
import Foundation

struct HotKeyConfiguration: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var keyDisplayName: String
    var usesCommand: Bool
    var usesOption: Bool
    var usesControl: Bool
    var usesShift: Bool

    init(
        keyCode: UInt32 = 9,
        keyDisplayName: String = "V",
        usesCommand: Bool = true,
        usesOption: Bool = true,
        usesControl: Bool = false,
        usesShift: Bool = false
    ) {
        self.keyCode = keyCode
        self.keyDisplayName = keyDisplayName
        self.usesCommand = usesCommand
        self.usesOption = usesOption
        self.usesControl = usesControl
        self.usesShift = usesShift
    }

    var carbonModifiers: UInt32 {
        var modifiers: UInt32 = 0
        if usesCommand { modifiers |= UInt32(cmdKey) }
        if usesOption { modifiers |= UInt32(optionKey) }
        if usesControl { modifiers |= UInt32(controlKey) }
        if usesShift { modifiers |= UInt32(shiftKey) }
        return modifiers
    }

    var displayName: String {
        var value = ""
        if usesControl { value += "⌃" }
        if usesOption { value += "⌥" }
        if usesShift { value += "⇧" }
        if usesCommand { value += "⌘" }
        return value + keyDisplayName
    }

    var isValid: Bool {
        carbonModifiers != 0 || Self.functionKeyCodes.contains(keyCode)
    }

    static let functionKeyCodes: Set<UInt32> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
        103, 111, 105, 107, 113, 106, 64, 79, 80, 90
    ]

    private enum CodingKeys: String, CodingKey {
        case keyCode
        case keyDisplayName
        case key
        case usesCommand
        case usesOption
        case usesControl
        case usesShift
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyKey = try container.decodeIfPresent(HotKeyLetter.self, forKey: .key)
        keyCode = try container.decodeIfPresent(UInt32.self, forKey: .keyCode) ?? legacyKey?.keyCode ?? 9
        keyDisplayName = try container.decodeIfPresent(String.self, forKey: .keyDisplayName)
            ?? legacyKey?.rawValue.uppercased()
            ?? "V"
        usesCommand = try container.decodeIfPresent(Bool.self, forKey: .usesCommand) ?? true
        usesOption = try container.decodeIfPresent(Bool.self, forKey: .usesOption) ?? true
        usesControl = try container.decodeIfPresent(Bool.self, forKey: .usesControl) ?? false
        usesShift = try container.decodeIfPresent(Bool.self, forKey: .usesShift) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(keyDisplayName, forKey: .keyDisplayName)
        try container.encode(usesCommand, forKey: .usesCommand)
        try container.encode(usesOption, forKey: .usesOption)
        try container.encode(usesControl, forKey: .usesControl)
        try container.encode(usesShift, forKey: .usesShift)
    }
}

extension HotKeyConfiguration {
    /// 只比较按键与修饰键组合；显示名不参与判断。
    func sameCombo(as other: HotKeyConfiguration) -> Bool {
        keyCode == other.keyCode && carbonModifiers == other.carbonModifiers
    }

    func matches(_ event: NSEvent) -> Bool {
        guard UInt32(event.keyCode) == keyCode else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.command) == usesCommand
            && flags.contains(.option) == usesOption
            && flags.contains(.control) == usesControl
            && flags.contains(.shift) == usesShift
    }
}

struct PanelShortcuts: Codable, Equatable, Sendable {
    var search: HotKeyConfiguration
    var toggleFavorite: HotKeyConfiguration
    var deleteItem: HotKeyConfiguration
    var pastePlainText: HotKeyConfiguration

    init(
        search: HotKeyConfiguration = .init(
            keyCode: 3, keyDisplayName: "F",
            usesCommand: true, usesOption: false, usesControl: false, usesShift: false
        ),
        toggleFavorite: HotKeyConfiguration = .init(
            keyCode: 1, keyDisplayName: "S",
            usesCommand: true, usesOption: false, usesControl: false, usesShift: false
        ),
        deleteItem: HotKeyConfiguration = .init(
            keyCode: 51, keyDisplayName: "⌫",
            usesCommand: true, usesOption: false, usesControl: false, usesShift: false
        ),
        pastePlainText: HotKeyConfiguration = .init(
            keyCode: 36, keyDisplayName: "↩",
            usesCommand: false, usesOption: false, usesControl: false, usesShift: true
        )
    ) {
        self.search = search
        self.toggleFavorite = toggleFavorite
        self.deleteItem = deleteItem
        self.pastePlainText = pastePlainText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PanelShortcuts()
        search = try container.decodeIfPresent(HotKeyConfiguration.self, forKey: .search) ?? defaults.search
        toggleFavorite = try container.decodeIfPresent(HotKeyConfiguration.self, forKey: .toggleFavorite)
            ?? defaults.toggleFavorite
        deleteItem = try container.decodeIfPresent(HotKeyConfiguration.self, forKey: .deleteItem)
            ?? defaults.deleteItem
        pastePlainText = try container.decodeIfPresent(HotKeyConfiguration.self, forKey: .pastePlainText)
            ?? defaults.pastePlainText
    }

    var labeled: [(label: String, configuration: HotKeyConfiguration)] {
        [
            ("搜索", search),
            ("收藏", toggleFavorite),
            ("删除", deleteItem),
            ("纯文本粘贴", pastePlainText)
        ]
    }

    func conflictDescription(globalHotKey: HotKeyConfiguration) -> String? {
        let entries = labeled + [("呼出面板", globalHotKey)]
        for first in entries.indices {
            for second in entries.indices where second > first {
                if entries[first].configuration.sameCombo(as: entries[second].configuration) {
                    return "“\(entries[first].label)”与“\(entries[second].label)”使用了相同按键"
                }
            }
        }
        return nil
    }

    func conflicts(with configuration: HotKeyConfiguration) -> Bool {
        labeled.contains { $0.configuration.sameCombo(as: configuration) }
    }
}

private enum HotKeyLetter: String, Codable, Sendable {
    case a, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z

    var keyCode: UInt32 {
        let codes: [HotKeyLetter: UInt32] = [
            .a: 0, .s: 1, .d: 2, .f: 3, .h: 4, .g: 5, .z: 6, .x: 7,
            .c: 8, .v: 9, .b: 11, .q: 12, .w: 13, .e: 14, .r: 15,
            .y: 16, .t: 17, .o: 31, .u: 32, .i: 34, .p: 35, .l: 37,
            .j: 38, .k: 40, .n: 45, .m: 46
        ]
        return codes[self] ?? 9
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var appearance: AppAppearance { didSet { persist() } }
    @Published var soundEnabled: Bool { didSet { persist() } }
    @Published var soundName: String { didSet { persist() } }
    @Published var limitByAge: Bool { didSet { persist() } }
    @Published var retentionDays: Int { didSet { persist() } }
    @Published var limitByCount: Bool { didSet { persist() } }
    @Published var maximumItems: Int { didSet { persist() } }
    @Published var previewDelay: Double { didSet { persist() } }
    @Published var hotKey: HotKeyConfiguration { didSet { persist() } }
    @Published var hotKeyValidationMessage: String?
    @Published var panelShortcuts: PanelShortcuts { didSet { persist() } }

    private let defaults: UserDefaults
    private var isLoading = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = AppAppearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        soundName = defaults.string(forKey: Keys.soundName) ?? "Tink"
        limitByAge = defaults.object(forKey: Keys.limitByAge) as? Bool ?? true
        retentionDays = defaults.object(forKey: Keys.retentionDays) as? Int ?? 30
        limitByCount = defaults.object(forKey: Keys.limitByCount) as? Bool ?? true
        maximumItems = defaults.object(forKey: Keys.maximumItems) as? Int ?? 500
        previewDelay = defaults.object(forKey: Keys.previewDelay) as? Double ?? 1.5
        hotKeyValidationMessage = nil
        if let data = defaults.data(forKey: Keys.hotKey),
           let decoded = try? JSONDecoder().decode(HotKeyConfiguration.self, from: data) {
            hotKey = decoded
        } else {
            hotKey = HotKeyConfiguration()
        }
        if let data = defaults.data(forKey: Keys.panelShortcuts),
           let decoded = try? JSONDecoder().decode(PanelShortcuts.self, from: data) {
            panelShortcuts = decoded
        } else {
            panelShortcuts = PanelShortcuts()
        }
        isLoading = false
    }

    var retentionCutoff: Date? {
        guard limitByAge else { return nil }
        return Calendar.current.date(byAdding: .day, value: -max(1, retentionDays), to: Date())
    }

    var itemLimit: Int? {
        limitByCount ? max(10, maximumItems) : nil
    }

    private func persist() {
        guard !isLoading else { return }
        defaults.set(appearance.rawValue, forKey: Keys.appearance)
        defaults.set(soundEnabled, forKey: Keys.soundEnabled)
        defaults.set(soundName, forKey: Keys.soundName)
        defaults.set(limitByAge, forKey: Keys.limitByAge)
        defaults.set(retentionDays, forKey: Keys.retentionDays)
        defaults.set(limitByCount, forKey: Keys.limitByCount)
        defaults.set(maximumItems, forKey: Keys.maximumItems)
        defaults.set(previewDelay, forKey: Keys.previewDelay)
        if let data = try? JSONEncoder().encode(hotKey) {
            defaults.set(data, forKey: Keys.hotKey)
        }
        if let data = try? JSONEncoder().encode(panelShortcuts) {
            defaults.set(data, forKey: Keys.panelShortcuts)
        }
    }

    private enum Keys {
        static let appearance = "appearance"
        static let soundEnabled = "soundEnabled"
        static let soundName = "soundName"
        static let limitByAge = "limitByAge"
        static let retentionDays = "retentionDays"
        static let limitByCount = "limitByCount"
        static let maximumItems = "maximumItems"
        static let previewDelay = "previewDelay"
        static let hotKey = "hotKey"
        static let panelShortcuts = "panelShortcuts"
    }
}
