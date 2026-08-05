import AppKit
import Foundation
import Testing
@testable import SSClip

@MainActor
struct AppAppearanceTests {
    @Test func appearanceDefaultsToSystemAndPersistsSelection() {
        let suiteName = "SSClipTests.Appearance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = AppSettings(defaults: defaults)
        #expect(initial.appearance == .system)

        initial.appearance = .dark
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.appearance == .dark)
    }

    @Test func invalidStoredAppearanceFallsBackToSystem() {
        let suiteName = "SSClipTests.Appearance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("sepia", forKey: "appearance")

        #expect(AppSettings(defaults: defaults).appearance == .system)
    }

    @Test func appearancesMapToExpectedAppKitNames() {
        #expect(AppAppearance.system.appearanceName == nil)
        #expect(AppAppearance.light.appearanceName == .aqua)
        #expect(AppAppearance.dark.appearanceName == .darkAqua)
    }
}
