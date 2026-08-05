import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: ClipboardStore
    @State private var folderName = ""
    @State private var tab: SettingsTab = .general
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginFailed = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.55)
            content
        }
        .frame(width: 580, height: 446)
        .background {
            ZStack {
                VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                Theme.panelTint
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SSCLIP")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 7)

            ForEach(SettingsTab.allCases) { item in
                SidebarButton(tab: item, isSelected: tab == item) {
                    tab = item
                }
            }

            Spacer()

            HStack(spacing: 7) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(Theme.accentDeep)
                Text("数据只保存在本机")
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .padding(.top, 16)
        .padding(.horizontal, 8)
        .frame(width: 158, alignment: .leading)
        .background(Color.primary.opacity(0.018))
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tab.title)
                        .font(.system(size: 17, weight: .semibold))
                    Text(tab.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 2)

                switch tab {
                case .general:
                    generalSettings
                case .shortcut:
                    shortcutSettings
                case .folder:
                    folderSettings
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 15) {
            SettingsSection(title: "外观") {
                SettingsRow {
                    HStack {
                        Text("外观模式")
                        Spacer()
                        Picker("外观模式", selection: $settings.appearance) {
                            Text("跟随系统").tag(AppAppearance.system)
                            Text("浅色").tag(AppAppearance.light)
                            Text("深色").tag(AppAppearance.dark)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 214)
                        .accessibilityLabel("外观模式")
                    }
                }
            }

            SettingsSection(title: "启动") {
                SettingsRow {
                    Toggle("登录时自动启动", isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                        .tint(Theme.controlFill)
                        .onChange(of: launchAtLogin) { enabled in
                            guard enabled != LaunchAtLogin.isEnabled else { return }
                            if LaunchAtLogin.setEnabled(enabled) {
                                launchAtLoginFailed = false
                            } else {
                                launchAtLoginFailed = true
                                launchAtLogin = LaunchAtLogin.isEnabled
                            }
                        }
                }
                if launchAtLoginFailed {
                    CardDivider()
                    SettingsRow {
                        Label("设置失败。请将 SSClip.app 移入“应用程序”文件夹后重试。", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.danger)
                    }
                }
            }

            SettingsSection(title: "剪贴板变化") {
                SettingsRow {
                    Toggle("播放提示音", isOn: $settings.soundEnabled)
                        .toggleStyle(.switch)
                        .tint(Theme.controlFill)
                }
                CardDivider()
                SettingsRow {
                    HStack {
                        Text("提示音")
                        Spacer()
                        Picker("提示音", selection: $settings.soundName) {
                            ForEach(["Tink", "Pop", "Glass", "Purr"], id: \.self) { Text($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 214)
                        .disabled(!settings.soundEnabled)
                    }
                }
                CardDivider()
                SettingsRow {
                    HStack {
                        Text("确认当前提示音")
                        Spacer()
                        Button("试听") {
                            NSSound(named: NSSound.Name(settings.soundName))?.play()
                        }
                        .buttonStyle(SoftButtonStyle())
                        .disabled(!settings.soundEnabled)
                    }
                }
            }

            SettingsSection(title: "保留策略") {
                SettingsRow {
                    Toggle("按时间清理", isOn: $settings.limitByAge)
                        .toggleStyle(.switch)
                        .tint(Theme.controlFill)
                }
                CardDivider()
                SettingsRow {
                    Stepper(
                        "保留 \(settings.retentionDays) 天以内",
                        value: $settings.retentionDays,
                        in: 1...365
                    )
                    .disabled(!settings.limitByAge)
                }
                CardDivider()
                SettingsRow {
                    Toggle("限制总条数", isOn: $settings.limitByCount)
                        .toggleStyle(.switch)
                        .tint(Theme.controlFill)
                }
                CardDivider()
                SettingsRow {
                    Stepper(
                        "最多 \(settings.maximumItems) 条（收藏不丢失）",
                        value: $settings.maximumItems,
                        in: 10...10_000,
                        step: 10
                    )
                    .disabled(!settings.limitByCount)
                }
            }

            SettingsSection(title: "预览") {
                SettingsRow(verticalPadding: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("停留后预览")
                            Spacer()
                            Text("\(settings.previewDelay, specifier: "%.2g") 秒")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.previewDelay, in: 0.5...4, step: 0.25)
                            .tint(Theme.controlFill)
                        Text("面板内按空格可立即预览。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var shortcutSettings: some View {
        VStack(alignment: .leading, spacing: 15) {
            SettingsSection(title: "呼出剪贴板") {
                SettingsRow(verticalPadding: 9) {
                    HStack {
                        Text("呼出面板")
                        Spacer()
                        recorder(
                            for: $settings.hotKey,
                            validate: { candidate in
                                settings.panelShortcuts.conflicts(with: candidate)
                                    ? "与面板内快捷键冲突" : nil
                            }
                        )
                    }
                }
                CardDivider()
                SettingsRow(verticalPadding: 9) {
                    HStack(alignment: .center, spacing: 12) {
                        Text("点击控件后按下新组合键，再次点击或按 ⎋ 取消。支持字母、数字、符号、方向键和 F1–F20。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button("恢复默认") {
                            settings.hotKey = HotKeyConfiguration()
                        }
                        .buttonStyle(SoftButtonStyle())
                    }
                }
                if let message = settings.hotKeyValidationMessage {
                    CardDivider()
                    SettingsRow {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.danger)
                            .accessibilityLabel("快捷键错误：\(message)")
                    }
                }
            }

            SettingsSection(title: "面板内快捷键（可自定义）") {
                panelShortcutRow(label: "搜索", keyPath: \.search)
                CardDivider()
                panelShortcutRow(label: "收藏或取消收藏", keyPath: \.toggleFavorite)
                CardDivider()
                panelShortcutRow(label: "删除当前选中记录", keyPath: \.deleteItem)
                CardDivider()
                panelShortcutRow(label: "纯文本粘贴（去除格式）", keyPath: \.pastePlainText)
                CardDivider()
                SettingsRow(verticalPadding: 9) {
                    HStack {
                        Spacer()
                        Button("全部恢复默认") {
                            settings.panelShortcuts = PanelShortcuts()
                        }
                        .buttonStyle(SoftButtonStyle())
                    }
                }
            }

            SettingsSection(title: "固定快捷键") {
                ShortcutHelpRow(keys: "1…9 / 0", label: "粘贴对应的第 1…10 条")
                CardDivider()
                ShortcutHelpRow(keys: "⌘1…9 / ⌘0", label: "粘贴对应条目（搜索输入时也可用）")
                CardDivider()
                ShortcutHelpRow(keys: "↩", label: "粘贴当前选中记录")
                CardDivider()
                ShortcutHelpRow(keys: "⌘← / ⌘→", label: "上一页 / 下一页")
                CardDivider()
                ShortcutHelpRow(keys: "Tab", label: "切换剪贴板 / 收藏")
                CardDivider()
                ShortcutHelpRow(keys: "↑ / ↓", label: "移动选择，跨页连续（搜索输入时也可用）")
                CardDivider()
                ShortcutHelpRow(keys: "Space", label: "立即预览")
                CardDivider()
                ShortcutHelpRow(keys: "⎋", label: "关闭搜索或面板")
            }

            SettingsSection(title: "系统权限") {
                SettingsRow(verticalPadding: 10) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("直接粘贴需要 macOS“辅助功能”权限。SSClip 不使用网络，所有历史都保存在本机。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Button("打开辅助功能设置") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(SoftButtonStyle())
                    }
                }
            }
        }
    }

    private func panelShortcutRow(
        label: String,
        keyPath: WritableKeyPath<PanelShortcuts, HotKeyConfiguration>
    ) -> some View {
        SettingsRow(verticalPadding: 9) {
            HStack {
                Text(label)
                Spacer()
                recorder(
                    for: Binding(
                        get: { settings.panelShortcuts[keyPath: keyPath] },
                        set: { settings.panelShortcuts[keyPath: keyPath] = $0 }
                    ),
                    validate: { candidate in
                        if candidate.sameCombo(as: settings.hotKey) {
                            return "与呼出面板快捷键冲突"
                        }
                        var proposed = settings.panelShortcuts
                        proposed[keyPath: keyPath] = candidate
                        return proposed.conflictDescription(globalHotKey: settings.hotKey)
                    }
                )
            }
        }
    }

    private func recorder(
        for configuration: Binding<HotKeyConfiguration>,
        validate: @escaping (HotKeyConfiguration) -> String?
    ) -> some View {
        HotKeyRecorderView(configuration: configuration, validate: validate)
            .frame(width: 170, height: 28)
            .background(
                Color(light: .white.opacity(0.60), dark: Theme.accentDeep.opacity(0.08)),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.accentDeep.opacity(0.50), lineWidth: 1)
            }
    }

    private var folderSettings: some View {
        let folderCounts = store.items.reduce(into: [UUID: Int]()) { counts, item in
            if let folderID = item.folderID {
                counts[folderID, default: 0] += 1
            }
        }

        return VStack(alignment: .leading, spacing: 15) {
            SettingsSection(title: "新建收藏夹") {
                SettingsRow(verticalPadding: 8) {
                    HStack(spacing: 9) {
                        TextField("新收藏夹名称", text: $folderName)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 9)
                            .frame(height: 28)
                            .background(Theme.subtleSurface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .onSubmit(addFolder)
                        Button("添加", action: addFolder)
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }

            SettingsSection(title: "收藏夹") {
                if store.folders.isEmpty {
                    SettingsRow(verticalPadding: 13) {
                        HStack(spacing: 9) {
                            Image(systemName: "star")
                                .foregroundStyle(Theme.pinkDeep)
                            Text("暂无收藏夹。你仍可使用“未分类收藏”。")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ForEach(Array(store.folders.enumerated()), id: \.element.id) { index, folder in
                        SettingsRow(verticalPadding: 7) {
                            HStack(spacing: 9) {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(Theme.pinkDeep)
                                Text(folder.name)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(folderCounts[folder.id, default: 0]) 条")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Button {
                                    store.removeFolder(folder)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(Theme.danger)
                                        .frame(width: 24, height: 24)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("删除收藏夹 \(folder.name)")
                            }
                        }
                        if index < store.folders.count - 1 {
                            CardDivider()
                        }
                    }
                }
            }

            SettingsSection(title: "历史记录") {
                SettingsRow(verticalPadding: 10) {
                    HStack(alignment: .center, spacing: 12) {
                        Text("删除收藏夹不会删除里面的内容，只会移到未分类收藏。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button("清除未收藏历史") {
                            store.removeAllHistoryKeepingFavorites()
                        }
                        .buttonStyle(DangerButtonStyle())
                    }
                }
            }
        }
    }

    private func addFolder() {
        if store.addFolder(named: folderName) != nil {
            folderName = ""
        }
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case shortcut
    case folder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "通用"
        case .shortcut: "快捷键"
        case .folder: "收藏夹"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "剪贴板反馈、保留策略与预览"
        case .shortcut: "呼出方式与面板内操作"
        case .folder: "整理收藏内容与清理历史"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .shortcut: "keyboard.fill"
        case .folder: "folder.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .general: Theme.settingsGeneralIcon
        case .shortcut: Theme.settingsShortcutIcon
        case .folder: Theme.settingsFolderIcon
        }
    }
}

private struct SidebarButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: tab.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(tab.iconColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(tab.title)
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .contentShape(Rectangle())
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(light: .white.opacity(0.90), dark: .white.opacity(0.10)))
                        .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.45)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            VStack(spacing: 0) {
                content
            }
            .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Theme.surfaceStroke, lineWidth: 1)
            }
        }
    }
}

private struct SettingsRow<Content: View>: View {
    let verticalPadding: CGFloat
    @ViewBuilder let content: Content

    init(verticalPadding: CGFloat = 7, @ViewBuilder content: () -> Content) {
        self.verticalPadding = verticalPadding
        self.content = content()
    }

    var body: some View {
        content
            .font(.system(size: 12))
            .padding(.horizontal, 13)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
    }
}

private struct CardDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 13)
            .opacity(0.45)
    }
}

private struct ShortcutHelpRow: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 12) {
            Text(keys)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.78))
                .padding(.horizontal, 7)
                .frame(minWidth: 82, minHeight: 22, alignment: .center)
                .background(
                    Color(light: .white.opacity(0.75), dark: .white.opacity(0.09)),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 30)
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.onControl)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Theme.controlFill.opacity(configuration.isPressed ? 0.76 : 1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct SoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary.opacity(configuration.isPressed ? 0.55 : 0.80))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Theme.subtleSurface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.danger.opacity(configuration.isPressed ? 0.65 : 1))
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
