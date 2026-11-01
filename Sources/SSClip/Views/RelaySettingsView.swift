import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Connection files are read directly; API keys never pass through the pasteboard.
struct RelaySettingsView: View {
    @EnvironmentObject private var relay: RelayController
    @EnvironmentObject private var settings: AppSettings
    @State private var deviceName = ""
    @State private var serviceURL = ""
    @State private var apiKey = ""
    @State private var importNotice = ""
    @State private var advancedExpanded = false

    private var destinations: [RelayDevice] {
        relay.devices.filter { $0.id != relay.deviceID }
    }
    private var hasTarget: Bool { destinations.contains { $0.id == relay.targetID } }
    private var visibleInbox: [RelayReceipt] { relay.currentInbox }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            if !relay.isConfigured {
                setupCard
            } else {
                dailyControls
            }

            VStack(alignment: .leading, spacing: 6) {
                if relay.isRegistering {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在连接并发现设备…")
                    }
                }
                Text(relay.status)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityLabel("同步状态：\(relay.status)")
                if let warning = relay.credentialWarning {
                    Text(warning).foregroundStyle(.red)
                }
                if !importNotice.isEmpty {
                    Text(importNotice).foregroundStyle(.secondary)
                }
            }
            .font(.caption)

            if relay.isConfigured {
                inboxSection
            }

            Divider()
            DisclosureGroup("连接与高级设置", isExpanded: $advancedExpanded) {
                advancedSettings.padding(.top, 8)
            }
            Text("只在点击发送时上传纯文本，最多 32 KiB。服务端明文暂存，最长 20 分钟有效，不是端到端加密；本机收件箱与历史另行保留。不要发送密码等敏感信息。Bark 尚未接入。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .onAppear { updateDrafts() }
        .onDisappear { apiKey = "" }
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("导入一次，之后直接收发", systemImage: "link")
                .font(.headline)
            Text("在管理端导出连接配置，然后在每台 Mac 导入同一份文件。不需要在每台设备登录，也不需要手选设备编号。")
                .foregroundStyle(.secondary)
            Button("导入连接配置…", action: chooseConfigurationFile)
                .buttonStyle(.borderedProminent)
            Text("配置文件含 API Key，只交给你自己的设备。导入后不会自动开启接收。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
    }

    private var dailyControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(.secondary)
                TextField("这台 Mac 的名称", text: $deviceName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("这台 Mac 的名称")
                    .onSubmit { saveDeviceName() }
                if deviceName != relay.deviceName {
                    Button("保存", action: saveDeviceName)
                        .disabled(deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            HStack {
                Picker("默认发送目标", selection: Binding(
                    get: { relay.targetID },
                    set: { relay.selectTarget($0) }
                )) {
                    Text("选择设备").tag("")
                    ForEach(destinations) { device in
                        Text(displayName(device)).tag(device.id)
                    }
                }
                Button { relay.refreshDevices() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新设备")
                .accessibilityLabel("刷新设备")
                .disabled(relay.isRegistering)
            }
            if destinations.isEmpty {
                Text("还没有其他设备。在另一台设备导入同一份连接配置后，点击刷新。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(relay.isSending ? "正在发送…" : "发送当前纯文本") {
                relay.sendCurrentClipboard()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasTarget || relay.isSending || relay.isRegistering)

            VStack(alignment: .leading, spacing: 7) {
                Toggle("全局快捷键发送", isOn: $settings.sendHotKeyEnabled)
                    .toggleStyle(.switch)
                HStack {
                    Text("发送到上方默认目标")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    HotKeyRecorderView(configuration: $settings.sendHotKey, validate: { settings.sendHotKeyConflict($0) })
                        .frame(width: 130, height: 26)
                        .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 6))
                }
                if let message = settings.sendHotKeyValidationMessage {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
                Text("预设 ⌃⌥⌘S，默认关闭。开启后无需打开窗口；按住不会连发。可点击键位重设，或关闭开关禁用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("自动接收", isOn: Binding(
                get: { relay.enabled },
                set: { relay.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .disabled(relay.isRegistering && !relay.enabled)
            Text("收到新文本时写入剪贴板，不自动粘贴。关闭接收后仍可手动发送。批量模式、断线积压或本机正在复制时，消息只进收件箱。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var inboxSection: some View {
        Divider()
        HStack {
            Text("收件箱").font(.headline)
            Spacer()
            Text("\(visibleInbox.count) 条").font(.caption).foregroundStyle(.secondary)
        }
        if visibleInbox.isEmpty {
            Text("收到的文本会保留在这里；暂存消息可随时手动复制。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(Array(visibleInbox.prefix(10)), id: \.identity) { receipt in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(senderName(receipt.source))
                        Spacer()
                        Text(receipt.receivedAt, style: .time)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text(receipt.text).lineLimit(3).textSelection(.enabled)
                    HStack {
                        Button("复制") { relay.copyReceipt(receipt) }
                            .disabled(relay.isBatchMode)
                        Button("移除") { relay.deleteReceipt(receipt) }
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 8))
            }
            if relay.isBatchMode {
                Text("批量模式中暂停手动复制，避免替换队首。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if visibleInbox.count > 10 {
                Text("显示最近 10 条；移除后可查看更早内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(relay.isConfigured ? "重新导入连接配置…" : "导入连接配置…", action: chooseConfigurationFile)
            Text("导入新服务端会关闭自动接收；同一服务端保留你已开启的接收选择。取消不会改变原配置。API Key 存系统钥匙串。文件包含密钥，导入后请妥善保管或自行删除，不要发送到剪贴板收件箱。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if relay.isConfigured {
                Text("服务端：\(relay.serviceURL)")
                    .font(.caption)
                    .textSelection(.enabled)
            }
            Text("本机 ID：\(relay.deviceID)")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Divider()
            Text("手动连接 / 自建服务端").font(.subheadline.weight(.semibold))
            TextField("HTTPS 服务端根地址", text: $serviceURL)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
            SecureField("API Key（不会显示已有密钥）", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .disabled(relay.isBatchMode)
            Button("保存手动连接", action: importManualConfiguration)
                .disabled(apiKey.isEmpty || serviceURL.isEmpty || relay.isBatchMode)
            Text("优先导入文件，避免密钥进入剪贴板历史。若手动输入，请先关闭批量模式；保存后自行复制普通文本替换系统剪贴板。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func displayName(_ device: RelayDevice) -> String {
        let duplicates = destinations.filter { $0.name == device.name }.count > 1
        return duplicates ? "\(device.name) · \(device.id.prefix(6))" : device.name
    }

    private func senderName(_ id: String) -> String {
        guard let device = relay.devices.first(where: { $0.id == id }) else { return "设备 · \(id.prefix(6))" }
        return displayName(device)
    }

    private func updateDrafts() {
        deviceName = relay.deviceName
        serviceURL = relay.serviceURL
        apiKey = ""
    }

    private func saveDeviceName() {
        relay.renameDevice(deviceName)
        deviceName = relay.deviceName
    }

    private func acceptConfiguration(_ data: Data) {
        if relay.importConfiguration(data: data) {
            updateDrafts()
            importNotice = "连接已导入，正在发现设备。需要自动接收时，请打开上方开关。"
        } else {
            importNotice = "配置未导入，原连接保持不变。请检查文件格式与密钥。"
        }
    }

    private func chooseConfigurationFile() {
        let panel = NSOpenPanel()
        panel.title = "导入 SSClip 连接配置"
        panel.message = "选择管理端导出的 .ssclip.json 文件；内容含 API Key，请勿分享。"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size <= 16_384 else {
                importNotice = "请选择不超过 16 KiB 的连接配置文件。"; return
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 16_385) ?? Data()
            guard data.count <= 16_384 else { importNotice = "连接配置文件过大，未导入。"; return }
            if let configuration = RelayConnectionConfiguration.parse(data), configuration.server_url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != relay.serviceURL {
                let alert = NSAlert()
                alert.messageText = "连接这个服务端？"
                alert.informativeText = "\(configuration.server_url)\n将向此地址发送文件中的 API Key 和本机名称以注册。只导入你自己管理端导出的配置。"
                alert.addButton(withTitle: "导入并连接")
                alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            acceptConfiguration(data)
        } catch {
            importNotice = "无法读取所选配置文件，原连接未改变。"
        }
    }

    private func importManualConfiguration() {
        let configuration: [String: Any] = ["format": "ssclip-connection", "version": 1,
                                            "server_url": serviceURL, "api_key": apiKey]
        guard let data = try? JSONSerialization.data(withJSONObject: configuration) else {
            importNotice = "手动连接无效，原连接未改变。"; return
        }
        acceptConfiguration(data)
        apiKey = ""
    }
}
