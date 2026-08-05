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
                settings: appModel.settings
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

    var body: some View {
        Button("打开剪贴板（\(settings.hotKey.displayName)）") {
            model.showPanel()
        }
        .keyboardShortcut("v", modifiers: [.command, .option])

        Button(model.isBatchMode ? "关闭批量模式（队列剩 \(model.batchItemIDs.count) 条）" : "开启批量模式") {
            model.toggleBatchMode()
        }

        Divider()

        if let storageErrorMessage = store.storageErrorMessage {
            Label(storageErrorMessage, systemImage: "exclamationmark.triangle.fill")
                .disabled(true)
        }

        Text("已保存 \(store.items.count) 条")
        Button("设置…") {
            model.showSettings()
        }
        Button("退出 SSClip") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
