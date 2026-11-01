# SSClip发送：单快捷指令、每次选择设备

## 使用
1. 在 Mac SSClip 中生成并通过 Apple 官方方式签名 `SSClip发送.shortcut`，在 iPhone 安装。只保留这一个快捷指令；旧“SSClip设置”可以删除。
2. 已成功导入过配置的 iPhone 无须重导入：沿用私有 state 的 server_url/api_key ；忽略旧 target_id/target_name，也不再读取旧 phone-id.txt。
3. 首次无配置时选择自己管理端导出的连接 JSON，确认实际 HTTPS 服务地址。注册成功后只保存连接，本次不读取或发送剪贴板。
4. 日常复制纯文本，运行“SSClip发送”，每次从实时设备列表选择本次接收设备（Mac 或已启用 Bark 的 iPhone/iPad）。取消不会发送，不保存默认目标。
5. 同一列表最后的“更换连接配置…”可重新导入；即使没有接收设备，也保留此入口。重新导入只保存连接，不发送。此入口内部调用同一快捷指令，因此请保留名称 **SSClip发送**。

## 边界与安全
- 设备标签包含完整 ID，同名设备不会混淆。目标仅取本次列表选择，不回退旧设备。
- 配置及 API Key 明文保存在本人 iCloud Drive/Shortcuts/SSClip/connection-state.json。勿分享配置/状态文件或快捷指令运行详情。同一 iCloud 账号的 iPhone/iPad 可共用该连接配置。所有快捷指令均注册为固定逻辑发送端 `ios-shortcut-sender` / “iOS 快捷指令”，`can_receive:false`；这不是某台物理手机身份，也不会出现在接收目标中。每台 iOS 的接收由各自独立 Bark 目标承担。旧 phone-id.txt 不再读取或修改。
- 严格 HTTPS 根地址，允许 ASCII 域名/IPv4、端口；不允许用户信息、路径、查询或片段，IPv6 请用域名。Shortcuts 原生 HTTP 无法在此模板中保证拒绝重定向，只信任自己管理端导出且控制的服务。
- 只接受文本类型；图片/文件不会转 OCR 或读内容上传。英文和中文系统文本标签已列入安全白名单，其他语言可能安全拒绝。
- 空文本、当前 API Key、疑似完整连接 JSON 被阻止。正文 32 KiB UTF-8 上限由服务端执行；没有复杂客户端字节算术。
- 成功只说明服务器接收，不保证接收设备已收到或复制；HTTP/未知结果不自动重试。20 分钟有效。
- 缺少 format、标记不匹配、缺少 version、版本不支持、URL/key 格式错误分类反馈，不回显值。已解析的本地版本/URL/key 无效、注册返回失败或身份不匹配时，直接提供“重新导入连接配置／取消”，取消不改旧配置，不涉及物理手机身份。损坏 JSON、原生文件或 HTTP 网络错误可能由系统提前终止，无法用此模板捕获；先恢复网络/服务再重试，若仍失败请反馈系统错误，不要求删除状态文件。

## 构建与验证事实
- 使用官方 Cherri v2.3.0 二进制，`--skip-sign`，禁用 `--derive-uuids`。所有字典键用显式原生 getvalueforkey，不用属性语法。`normalize_shortcuts.py` 清理错误命名变量输出元数据。
- 当前只有一个模板：513 个原生 actions，3014 项结构/隐私/实际字典 fixture/旧状态兼容/控制流检查通过。`build_unsigned.py` 只生成发送模板，不生成设置 helper。
- 用户已在 iPhone 安装旧版并验证修复后的配置成功；尚不能据此声称发送成功。此轮“每次选择设备”新模板仍需重新签名、安装并实机验证。静态测试不是 iOS 模拟器。
- 签名输入和输出均使用名称 `SSClip发送.shortcut`；资源 `SSClip-Send.unsigned.shortcut` 本身未签名。不要把 unsigned 文件当作现成可安装文件。

接收列表只列 macos 或 platform=ios 且 transport=bark；普通旧 iOS relay 注册记录不作为收件端。显式 can_receive:false 接收端也排除：原生字典转 JSON 后匹配 JSON 布尔 false，不依赖本地化“是/否”文本；字段缺失兼容旧服务，字符串 "false" 不当作布尔。共享发送源另按固定 ID 排除。Bark 返回 pending/submitted 时仍只显示服务端接受，不代表手机已收到。

## 重复要求配置的修订
用户已确认现有 `iCloud Drive/Shortcuts/SSClip/connection-state.json` 存在，而且先显示“连接 SSClip”确认再出现配置选择器。因此问题在加载/存在判断链路；不能把扩展名推测当成已证实原因。

本候选保留原 `.json` 文件和保存位置，不重命名、不迁移、不删除。加载使用真实 Apple Frames 导出中观察到的现代形态：`WFGetFilePath=/SSClip/connection-state.json`、`WFFileErrorIfNotFound=false`，不再放旧 provider/picker 参数；通过 Count Items 判断存在，再明确 File→Text→Dictionary。

新保存加入 format 标记；只有从同一冷启动 loader 再次读出，并确认 format、version、server_url、api_key 四项一致，才显示“已保存并读回校验”。失败不会回显值或伪报保存成功。API Key 出现在剪贴板任意位置也会阻止发送，覆盖旧无 format 状态全文。

`test_persistence_actions.py` 直接解释生成的原生动作子集：三次全新变量环境只共享虚拟文件映射，第一次导入，第二/三次到目标选择；旧状态兼容；保存错路径/provider及四项读回不匹配都不得成功。5 个测试组通过。文件提供器模型按观察到的现代 Shortcuts-root 语义声明，不模拟 iCloud/权限/迁移，不能代替本次 iPhone 实测。
