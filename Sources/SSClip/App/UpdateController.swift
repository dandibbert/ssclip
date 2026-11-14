import AppKit
import Combine
import Foundation

@MainActor
final class UpdateController: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableUpdate)
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?

    let currentVersion: String
    let isSupported: Bool

    private let settings: AppSettings
    private let defaults: UserDefaults
    private let checker: UpdateChecker
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    init(
        settings: AppSettings,
        defaults: UserDefaults = .standard,
        checker: UpdateChecker = UpdateChecker(),
        bundle: Bundle = .main
    ) {
        self.settings = settings
        self.defaults = defaults
        self.checker = checker
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        isSupported = bundle.bundleURL.pathExtension == "app"
        lastChecked = defaults.object(forKey: Keys.lastChecked) as? Date
    }

    func start() {
        settings.$automaticallyChecksForUpdates
            .removeDuplicates()
            .sink { [weak self] enabled in self?.scheduleAutomaticChecks(enabled) }
            .store(in: &cancellables)
    }

    var availableUpdate: AvailableUpdate? {
        if case let .available(update) = state { return update }
        return nil
    }

    var isBusy: Bool {
        state == .checking || state == .installing
    }

    func checkForUpdates() {
        check(userInitiated: true)
    }

    func installAvailableUpdate() {
        guard let availableUpdate else { return }
        install(availableUpdate)
    }

    static func isNewer(_ update: AvailableUpdate, than currentVersion: String) -> Bool {
        guard let current = AppVersion(currentVersion) else { return true }
        return update.version > current
    }

    static func isDue(lastChecked: Date?, now: Date = Date()) -> Bool {
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) >= automaticCheckInterval || lastChecked > now
    }

    private func scheduleAutomaticChecks(_ enabled: Bool) {
        timer?.invalidate()
        timer = nil
        guard enabled, isSupported else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        // 刚启动时网络和登录项可能还没就绪，稍等再查。
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.checkIfDue()
        }
    }

    private func checkIfDue() {
        guard settings.automaticallyChecksForUpdates, Self.isDue(lastChecked: lastChecked) else { return }
        check(userInitiated: false)
    }

    private func check(userInitiated: Bool) {
        guard !isBusy else { return }
        state = .checking
        Task {
            do {
                let update = try await checker.fetchLatest(currentVersion: currentVersion)
                recordCheck()
                guard Self.isNewer(update, than: currentVersion) else {
                    state = .upToDate
                    if userInitiated { presentUpToDate() }
                    return
                }
                state = .available(update)
                if userInitiated || defaults.string(forKey: Keys.skippedTag) != update.tagName {
                    presentAvailable(update, userInitiated: userInitiated)
                }
            } catch {
                state = .failed("检查更新失败：\(error.localizedDescription)")
                if userInitiated {
                    presentFailure("检查更新失败", error: error, pageURL: nil)
                }
            }
        }
    }

    private func install(_ update: AvailableUpdate) {
        guard state != .installing else { return }
        guard isSupported else {
            NSWorkspace.shared.open(update.pageURL)
            return
        }
        state = .installing
        Task {
            do {
                try await UpdateInstaller().install(update)
            } catch {
                state = .available(update)
                presentFailure("安装更新失败", error: error, pageURL: update.pageURL)
            }
        }
    }

    private func recordCheck() {
        let now = Date()
        lastChecked = now
        defaults.set(now, forKey: Keys.lastChecked)
    }

    private func presentAvailable(_ update: AvailableUpdate, userInitiated: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "SSClip \(update.version) 可以更新"
        var details = "当前版本 \(currentVersion)。更新后 SSClip 会自动重新打开，历史记录和设置保持不变。"
        let notes = update.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            details += "\n\n" + (notes.count > 600 ? String(notes.prefix(600)) + "…" : notes)
        }
        alert.informativeText = details
        alert.addButton(withTitle: isSupported ? "立即更新" : "打开下载页")
        alert.addButton(withTitle: "稍后")
        if !userInitiated {
            alert.addButton(withTitle: "跳过这个版本")
        }
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            defaults.removeObject(forKey: Keys.skippedTag)
            install(update)
        case .alertThirdButtonReturn:
            defaults.set(update.tagName, forKey: Keys.skippedTag)
        default:
            break
        }
    }

    private func presentUpToDate() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "SSClip 已是最新版本"
        alert.informativeText = "当前版本 \(currentVersion)。"
        alert.runModal()
    }

    private func presentFailure(_ title: String, error: Error, pageURL: URL?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        if pageURL != nil {
            alert.addButton(withTitle: "打开下载页")
        }
        if alert.runModal() == .alertSecondButtonReturn, let pageURL {
            NSWorkspace.shared.open(pageURL)
        }
    }

    private enum Keys {
        static let lastChecked = "updateLastChecked"
        static let skippedTag = "updateSkippedTag"
    }
}
