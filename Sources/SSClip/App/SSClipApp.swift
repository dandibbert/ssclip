import AppKit
import Combine
import SwiftUI

@main
struct SSClipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(appDelegate.appModel)
                .environmentObject(appDelegate.appModel.store)
                .environmentObject(appDelegate.appModel.settings)
                .environmentObject(appDelegate.updateController)
        } label: {
            Label {
                Text("SSClip")
            } icon: {
                Image(nsImage: MenuBarIcon.image)
                    .accessibilityHidden(true)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appModel = AppModel()
    lazy var updateController = UpdateController(settings: appModel.settings)
    private var panelController: ClipboardPanelController?
    private var settingsWindowController: SettingsWindowController?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppearance(appModel.settings.appearance)
        appModel.settings.$appearance
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] appearance in
                self?.applyAppearance(appearance)
            }
            .store(in: &cancellables)

        NSApp.setActivationPolicy(.accessory)
        appModel.panelProvider = { [weak self] in
            guard let self else { return nil }
            if let panelController = self.panelController { return panelController }
            let controller = ClipboardPanelController(model: self.appModel)
            self.panelController = controller
            self.appModel.panelController = controller
            return controller
        }
        appModel.settingsPresenter = { [weak self] in
            self?.showSettingsWindow()
        }
        appModel.start()
        updateController.start()
        if ProcessInfo.processInfo.arguments.contains("--show-panel") {
            DispatchQueue.main.async { [weak appModel] in appModel?.showPanel() }
        }
        if ProcessInfo.processInfo.arguments.contains("--show-settings") {
            DispatchQueue.main.async { [weak appModel] in appModel?.showSettings() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        try? appModel.store.saveImmediately()
    }

    private func showSettingsWindow() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                store: appModel.store,
                settings: appModel.settings,
                updateController: updateController,
                relay: appModel.relay
            )
        }
        settingsWindowController?.show()
    }

    private func applyAppearance(_ appearance: AppAppearance) {
        NSApp.appearance = appearance.appearanceName.flatMap(NSAppearance.init(named:))
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: ClipboardStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var updater: UpdateController

    var body: some View {
        Button("打开剪贴板（\(settings.hotKey.displayName)）") {
            model.showPanel()
        }
        .keyboardShortcut("v", modifiers: [.command, .option])

        Button(model.isBatchMode ? "关闭批量模式（队列剩 \(model.batchItemIDs.count) 条）" : "开启批量模式") {
            model.toggleBatchMode()
        }

        Button(settings.capturePaused ? "恢复记录剪贴板" : "暂停记录剪贴板") {
            settings.capturePaused.toggle()
        }

        Divider()

        if let storageErrorMessage = store.storageErrorMessage {
            Label(storageErrorMessage, systemImage: "exclamationmark.triangle.fill")
                .disabled(true)
        }

        RelayMenuContent(relay: model.relay)
        Divider()

        Text(settings.capturePaused
            ? "已暂停记录 · 已保存 \(store.items.count) 条"
            : "已保存 \(store.items.count) 条")
        Button("设置…") {
            model.showSettings()
        }
        .keyboardShortcut(",")
        if let update = updater.availableUpdate {
            Button("更新到 \(update.version)…") {
                updater.installAvailableUpdate()
            }
            .disabled(updater.isBusy)
        } else {
            Button(updater.state == .installing ? "正在安装更新…" : "检查更新…") {
                updater.checkForUpdates()
            }
            .disabled(updater.isBusy)
        }
        Button("退出 SSClip") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

private struct RelayMenuContent: View {
    @ObservedObject var relay: RelayController
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Button("发送当前纯文本 → \(destinationName)  \(shortcutLabel)") {
            relay.sendCurrentClipboard()
        }
        .disabled(!relay.isConfigured || relay.isSending || relay.isRegistering || !relay.devices.contains(where: { $0.id == relay.targetID && $0.id != relay.deviceID && $0.canReceive }))
        Text(relay.status)
            .font(.caption)
    }

    private var shortcutLabel: String {
        settings.sendHotKeyEnabled ? "（\(settings.sendHotKey.displayName)）" : "（快捷键未开启）"
    }

    private var destinationName: String {
        guard let target = relay.devices.first(where: { $0.id == relay.targetID && $0.canReceive }) else { return "未选择默认目标" }
        let duplicates = relay.devices.filter { $0.name == target.name }.count > 1
        return duplicates ? "\(target.name) · \(target.id)" : target.name
    }
}
