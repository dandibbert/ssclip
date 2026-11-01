import Foundation
import Testing
@testable import SSClip

@MainActor
struct SendShortcutTests {
    @Test func safePresetStartsDisabledWithoutChangingExistingShortcuts() throws {
        let (settings, defaults, suite) = try context()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!settings.sendHotKeyEnabled)
        #expect(settings.sendHotKey == .defaultSend)
        #expect(settings.sendHotKey.displayName == "⌃⌥⌘S")
        #expect(settings.hotKey == HotKeyConfiguration())
        #expect(settings.panelShortcuts == PanelShortcuts())
        #expect(settings.sendHotKeyConflict(settings.sendHotKey) == nil)
    }

    @Test func senderPreferenceAndCustomKeyPersistIndependently() throws {
        let (settings, defaults, suite) = try context()
        defer { defaults.removePersistentDomain(forName: suite) }
        var key = HotKeyConfiguration.defaultSend
        key.keyCode = 2; key.keyDisplayName = "D"
        settings.sendHotKey = key
        settings.sendHotKeyEnabled = true
        let restored = AppSettings(defaults: defaults)
        #expect(restored.sendHotKeyEnabled)
        #expect(restored.sendHotKey == key)
        #expect(restored.hotKey == settings.hotKey)
        #expect(restored.panelShortcuts == settings.panelShortcuts)
    }

    @Test func conflictsRejectExistingBindingsCommonTypingAndSystemCombinations() throws {
        let (settings, defaults, suite) = try context()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(settings.sendHotKeyConflict(settings.hotKey) != nil)
        #expect(settings.sendHotKeyConflict(settings.panelShortcuts.search) != nil)
        #expect(settings.sendHotKeyConflict(.init(keyCode: 8, keyDisplayName: "C", usesCommand: true, usesOption: false)) != nil)
        #expect(settings.sendHotKeyConflict(.init(keyCode: 49, keyDisplayName: "Space", usesCommand: true, usesOption: true)) != nil)
        #expect(settings.sendHotKeyConflict(.init(keyCode: 53, keyDisplayName: "Esc", usesCommand: true, usesOption: true)) != nil)
    }

    @Test func unsuccessfulReplacementRetainsWorkingBindingAndVisibleReason() throws {
        let (settings, defaults, suite) = try context()
        defer { defaults.removePersistentDomain(forName: suite) }
        var registered: [HotKeyConfiguration] = []
        var unregisters = 0
        let binding = SendShortcutBinding(settings: settings, register: { key in
            registered.append(key); return key == .defaultSend
        }, unregister: { unregisters += 1 })
        settings.sendHotKeyEnabled = true
        binding.refresh()
        var replacement = HotKeyConfiguration.defaultSend
        replacement.keyCode = 2; replacement.keyDisplayName = "D"
        settings.sendHotKey = replacement
        binding.refresh()
        #expect(settings.sendHotKeyEnabled)
        #expect(settings.sendHotKey == .defaultSend)
        #expect(unregisters == 0)
        #expect(registered.count == 2)
        #expect(settings.sendHotKeyValidationMessage?.contains("保留上一组") == true)
        binding.refresh() // Published restoration must not erase the error or rebind.
        #expect(registered.count == 2)
        #expect(settings.sendHotKeyValidationMessage?.contains("保留上一组") == true)
    }

    @Test func disablingUnregistersAndReenablingRegistersAgain() throws {
        let (settings, defaults, suite) = try context()
        defer { defaults.removePersistentDomain(forName: suite) }
        var registrations = 0; var unregisters = 0
        let binding = SendShortcutBinding(settings: settings, register: { _ in registrations += 1; return true }, unregister: { unregisters += 1 })
        settings.sendHotKeyEnabled = true; binding.refresh()
        settings.sendHotKeyEnabled = false; binding.refresh()
        #expect(registrations == 1)
        #expect(unregisters == 1)
        settings.sendHotKeyEnabled = true; binding.refresh()
        #expect(registrations == 2)
    }

    @Test func changedPanelConflictDisablesSenderAndPreservesPanelChoice() throws {
        let (settings, defaults, suite) = try context()
        defer { defaults.removePersistentDomain(forName: suite) }
        var unregisters = 0
        let binding = SendShortcutBinding(settings: settings, register: { _ in true }, unregister: { unregisters += 1 })
        settings.sendHotKeyEnabled = true; binding.refresh()
        var panel = settings.panelShortcuts
        panel.search = .defaultSend
        settings.panelShortcuts = panel
        binding.refresh()
        #expect(!settings.sendHotKeyEnabled)
        #expect(settings.panelShortcuts == panel)
        #expect(unregisters == 1)
        #expect(settings.sendHotKeyValidationMessage?.contains("冲突") == true)
    }

    @Test func invalidLoadedEnabledConfigurationFailsClosedWithoutRegistration() throws {
        let (_, defaults, suite) = try context()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "sendHotKeyEnabled")
        defaults.set(try JSONEncoder().encode(HotKeyConfiguration()), forKey: "sendHotKey")
        let settings = AppSettings(defaults: defaults)
        var registered = false
        let binding = SendShortcutBinding(settings: settings, register: { _ in registered = true; return true }, unregister: {})
        binding.refresh()
        #expect(!registered)
        #expect(!settings.sendHotKeyEnabled)
        #expect(settings.sendHotKeyValidationMessage != nil)
    }

    private func context() throws -> (AppSettings, UserDefaults, String) {
        let suite = "SSClipSendShortcutTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (AppSettings(defaults: defaults), defaults, suite)
    }
}
