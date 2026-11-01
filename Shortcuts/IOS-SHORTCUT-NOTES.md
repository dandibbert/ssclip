# SSClip iOS 发送快捷指令 — unsigned 模板

**这两个文件不是已经可安装的成品。** 当前 GitHub macOS runner 的 Apple 官方 `shortcuts sign --mode anyone` 因未登录 iCloud 失败；需要由已登录 Apple 账户的授权 Mac 进行官方签名，再把签名后的文件发到 iPhone。不要绕过此限制，也不要把含真实 API Key 的已配置快捷指令送到第三方签名服务。

## 签名后的用户流程

1. 在 iPhone 安装主快捷指令，名称必须保留 **SSClip发送**。可选安装 **SSClip设置**，以后改目标或重新导入时使用。
2. 第一次运行“SSClip发送”，选管理端导出的 `ssclip-connection…json`，再选默认 Mac。此过程不读取或发送剪贴板。
3. 按系统提示允许访问本人 iCloud Drive 的 Shortcuts 文件夹与自己的 SSClip 域名。配置完成后，复制文本，再运行“SSClip发送”即可。
4. 日常不再选择文件或目标。可把主快捷指令加入主屏幕、操作按钮或轻点背面；这些系统入口需要用户自行选择。
5. 需要换默认 Mac 或配置，运行“SSClip设置”。**不要重命名主快捷指令**，设置入口通过固定名称调用它。

## 行为与限制

- 模板使用配置中的 `server_url`，严格限制为 HTTPS 根地址（支持 ASCII 域名/IPv4 和可选 1–65535 端口；拒绝账号密码、路径、查询、片段、控制字符，本版 IPv6 请使用域名）。首次/重新导入会显示实际地址，须用户明确确认后才发送 Key 与设备名。只导入本人可信管理端导出的文件。Shortcuts HTTP action 没有使用可验证的禁止重定向参数，因此不声称具备 Mac 客户端同等的重定向拒绝保证；服务端应保持这些 API 无重定向。
- Key 仅来自用户选择的文件，放 `Authorization: Bearer` header，不进 URL、通知、剪贴板或公开产物默认值。动态正文通过原生 Dictionary/JSON 请求字段序列化，保留中文、emoji、换行、引号和反斜线。
- 发送正文由服务端执行 32 KiB UTF-8 上限；快捷指令不再自行做复杂 Base64/算术预检。超过限制不得报成功。
- 状态明文保存在本人 **iCloud Drive / Shortcuts / SSClip / connection-state.json**；手机路由 ID 独立保存在 `phone-id.txt`，首次生成后持久保留。这里是随机 `ios-…` 路由 ID，不是 Apple 硬件标识或权限凭据。不要分享这些文件。iCloud 同账号多台 iPhone 会共享这些文件，本版针对用户的一台 iPhone；不能宣称多手机隔离。
- 每次先注册本机、读取设备列表，只允许 `platform=macos` 的目标。原目标消失则停止，不偷偷改发另一台。首次或设置模式选择成功后才写连接状态；取消文件/列表选择不覆盖旧连接。
- 图片和文件通过 Get Type 检查拒绝，不做 OCR。允许 Text/Rich Text 及中英文对应类型名；其他语言系统的类型标签未现场验证。
- 空内容、已知 API Key、疑似完整连接配置不会发送。重复 Create Folder 的行为尚待实机验证。
- 一次运行只 POST send 一次，不自动重试。只有返回 ID 匹配且 `state=pending` 才提示“服务器已接收”，不表示 Mac 已复制。`acknowledged` 仅提示服务器记录接收端确认，不谎称剪贴板已写入。网络/系统动作错误可能由 Shortcuts 原生错误界面呈现，停止运行；不要盲目重发。
- 旧状态损坏时，可运行“SSClip设置”并选“重新导入连接配置”，该分支会跳过旧 JSON 解析。若 `phone-id.txt` 损坏，需要在文件 App 删除该身份文件后重新运行（会注册为新手机）。

## 构建与证据

- 编译器：Cherri **v2.3.0**，通过 `--skip-sign` 明确禁用签名；没有请求第三方签名服务。
- 编译器 release：`https://github.com/electrikmilk/cherri/releases/tag/v2.3.0`
- Linux x86_64 release ZIP SHA256：`7ab2c384b7b26e7c72a30a8dfa56f89dae12c4068b7951bc1e3193f3698edbe9`
- 源：`SSClip-send.cherri`、`SSClip-settings.cherri`。
- 运行 `CHERRI=/path/to/cherri python3 build_unsigned.py` 可重建。
- 主模板 392 个原生 actions；可选设置模板 4 个 actions。验证包括实际生成的字典读取动作、合法/非法配置 fixture、控制流分组栈、引用、隐私参数；仍非 iOS 运行模拟。
- 禁用 Cherri --derive-uuids（它会复用独立 If 的分组 ID）；所有字典键改用显式 getvalueforkey 动作，不用对象属性语法。normalize 清除命名变量的错误 OutputUUID 元数据。
- 尚未验证：Apple 签名成功、iPhone 导入、iCloud 文件 action 实际运行、系统授权交互及生产端到端发送。因此不能以静态验证替代真实安装成功声明。

## 主要依据

- Apple 官方命令行签名说明：https://support.apple.com/guide/shortcuts-mac/apd455c82f02/mac
- Cherri 编译器、原生 action 定义：https://github.com/electrikmilk/cherri
- Get File / Save File 原生参数定义（scpl 项目提取的 action schema）：https://docs.scpl.dev/actions/getfile 与 https://docs.scpl.dev/actions/savefile

### 实机进展（2026-11-01 修订）
旧版已由用户在 Mac 官方签名后安装到 iPhone，并真实运行到选择连接配置；因此“签名 → 安装”链路已有用户使用证据。旧版在合法配置识别处失败，尚未证明注册/发送成功。本次修复模板需要重新签名、替换并在 iPhone 重试；不能把结构回归通过写成修复版实机通过。

配置错误提示分别区分缺少 format、format 标记不匹配、缺少 version、版本不支持、URL 不合规和 API Key 格式错误，不回显值。无法解析的 JSON 由系统“获取字典”动作直接报错；模板没有伪装成可捕获全部原生错误。
