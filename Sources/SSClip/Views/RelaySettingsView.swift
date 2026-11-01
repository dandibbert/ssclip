import AppKit
import SwiftUI

/// Credentials are never loaded back into this view or put onto the pasteboard.
struct RelaySettingsView: View {
    @EnvironmentObject private var relay: RelayController
    @State private var serviceURL = ""
    @State private var deviceID = ""
    @State private var targetID = ""
    @State private var token = ""
    @State private var savedNotice = ""

    private var hasChanges: Bool {
        serviceURL != relay.serviceURL || deviceID != relay.deviceID ||
        targetID != relay.targetID || !token.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("启用手动发送与自动接收", isOn: Binding(
                    get: { relay.enabled },
                    set: { relay.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .disabled(hasChanges)
                Text(relay.status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityLabel("同步状态：\(relay.status)")
                if hasChanges {
                    Text("请先保存配置，再启用同步。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 9) {
                Text("服务端地址（HTTPS）").font(.caption)
                TextField("https://…chatgpt.site", text: $serviceURL)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .accessibilityLabel("同步服务端地址")
                Picker("这台 Mac", selection: $deviceID) {
                    ForEach(RelayController.devices.filter { $0.id != "iphone-test" }, id: \.id) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                Picker("发送到", selection: $targetID) {
                    ForEach(RelayController.devices, id: \.id) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                if deviceID == targetID {
                    Text("发送目标不能是这台 Mac。")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("两台 Mac 要选择不同的本机身份。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("服务凭据").font(.caption)
                    Spacer()
                    Button("打开配对页面") {
                        guard let url = URL(string: relay.serviceURL), url.scheme == "https" else { return }
                        NSWorkspace.shared.open(url)
                    }
                }
                SecureField(relay.hasCredential ? "已保存在钥匙串；留空不更换" : "粘贴配对页面提供的服务凭据", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .accessibilityLabel("服务凭据（保存到系统钥匙串）")
                Text("保存后凭据写入系统钥匙串，并移除 SSClip 历史中的匹配文本。复制配对凭据期间可能暂时被剪贴板工具记录；请勿用其他同步工具转发。保存后请自行复制普通文本替换系统剪贴板。更换服务端时请同时输入新凭据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("保存配置（暂停同步）") {
                    if relay.configure(serviceURL: serviceURL, deviceID: deviceID, targetID: targetID,
                                       token: token.isEmpty ? nil : token) {
                        token = ""
                        serviceURL = relay.serviceURL
                        deviceID = relay.deviceID
                        targetID = relay.targetID
                        savedNotice = "已保存。确认配置后，打开上方开关。"
                    } else {
                        savedNotice = "未保存，请检查地址、设备与凭据。"
                    }
                }
                .disabled(deviceID == targetID)
                if !savedNotice.isEmpty {
                    Text(savedNotice).font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()

            Button(relay.isSending ? "正在发送…" : "发送当前剪贴板的纯文本") {
                relay.sendCurrentClipboard()
            }
            .disabled(!relay.enabled || relay.isSending || hasChanges)
            Text("只在点击发送时上传，最大 32 KiB。服务端接收成功不等于对方已复制。自动接收只写剪贴板，不模拟粘贴；批量模式或过旧消息会保留待手动处理，避免覆盖正在使用的内容。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !relay.inbox.filter({ !$0.hidden }).isEmpty {
                Divider()
                Text("已接收 · 本机收件箱").font(.headline)
                Text("以下内容已保存到本机明文收件箱；需要时手动复制。批量模式下不会覆盖队首。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(relay.inbox.filter { !$0.hidden }.prefix(10))) { receipt in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(RelayController.devices.first(where: { $0.id == receipt.source })?.name ?? receipt.source)
                            Spacer()
                            Text(receipt.receivedAt, style: .time)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Text(receipt.text)
                            .lineLimit(3)
                            .textSelection(.enabled)
                        HStack {
                            Button("复制") { relay.copyReceipt(receipt) }
                            Button("移出收件箱") { relay.deleteReceipt(receipt) }
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 8))
                }
                if relay.inbox.filter({ !$0.hidden }).count > 10 {
                    Text("显示最近 10 条；移出后可查看更早内容。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("实验版：服务端明文暂存，最长 20 分钟有效；不是端到端加密。本机收件箱与历史不会随服务端过期而自动删除，请按需清理。不要用于密码等敏感信息。iPhone 的 Bark 接收尚未接入，请先在两台 Mac 与网页之间测试。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .onAppear {
            serviceURL = relay.serviceURL
            deviceID = relay.deviceID
            targetID = relay.targetID
            token = ""
        }
        .onDisappear { token = "" }
    }
}
