import Foundation

/// Keeps the previous working OS binding when a replacement cannot be registered.
/// Called after published settings settle, never from @Published's willSet callback.
@MainActor
final class SendShortcutBinding {
    private let settings: AppSettings
    private let register: (HotKeyConfiguration) -> Bool
    private let unregister: () -> Void
    private var accepted: HotKeyConfiguration?
    private var applying = false

    init(settings: AppSettings, register: @escaping (HotKeyConfiguration) -> Bool, unregister: @escaping () -> Void) {
        self.settings = settings; self.register = register; self.unregister = unregister
    }

    func refresh() {
        guard !applying else { return }
        applying = true
        defer { applying = false }
        guard settings.sendHotKeyEnabled else { unregister(); accepted = nil; return }
        let candidate = settings.sendHotKey
        let conflict = settings.sendHotKeyConflict(candidate)
        if conflict == nil, accepted == candidate { return }
        if conflict == nil && register(candidate) {
            accepted = candidate
            settings.sendHotKeyValidationMessage = nil
            return
        }
        let message = conflict ?? "快捷键已被其他应用占用或注册失败，请换一组"
        if let accepted, settings.sendHotKeyConflict(accepted) == nil {
            settings.sendHotKey = accepted
            settings.sendHotKeyValidationMessage = message + "；已保留上一组发送快捷键"
        } else {
            unregister(); accepted = nil
            settings.sendHotKeyEnabled = false
            settings.sendHotKeyValidationMessage = message + "；发送快捷键未启用"
        }
    }
}
