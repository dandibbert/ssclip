# Action schema 依据与验证边界

本包没有取得用户 iPhone 的真实导出样本，也没有已成功安装并运行的 Apple 设备环境。Apple 官方未在所查资料中公开完整 `.shortcut` plist schema；因此不能声称“Apple 官方格式验证通过”。

采用 **Cherri v2.3.0 原生 action 定义**作为编译器 primary source，通过同版本真实编译器产出 plist，再对结构与秘密流向检查。源码条目：

- `actions/documents.cherri`：`file.select`、`documentpicker.open`、`documentpicker.save`、`file.createfolder`，字段 `WFGetFilePath`、`WFFileErrorIfNotFound`、`WFFileDestinationPath`、`WFAskWhereToSave`、`WFSaveFileOverwrite`、`WFInput`。
- `actions/web.cherri`：`downloadurl`，`WFURL`、`WFHTTPMethod`、`WFHTTPHeaders`、`WFHTTPBodyType=JSON`、`WFJSONValues`。
- `actions/basic.cherri`：`getitemtype`、`detect.dictionary`、`getvalueforkey`、`setvalueforkey`、`choosefromlist`、`number.random`、`count`、`alert`、`exit`。
- `actions/device.cherri`：`getdevicedetails`，`WFDeviceDetail=Device Name`。
- `actions/sharing.cherri`：`getclipboard`。
- `actions/crypto.cherri`：`base64encode`。产物后处理明确 `WFEncodeMode=Encode`，避免依赖默认参数。
- `actions/text.cherri`：`text.match`、`text.replace`、`detect.text`。
- `actions/shortcuts.cherri`：`runworkflow`，`WFWorkflowName` 和 `WFInput`。
- `shortcut.go`、`shortcutgen.go`：`WFDictionaryFieldValueItems`、`WFTextTokenString`、`WFTextTokenAttachment`、动态变量引用与数字 Dictionary item 序列化。

固定版本源链接：https://github.com/electrikmilk/cherri/tree/v2.3.0/actions

已实际 fetch 并核对 tag `v2.3.0` 对应 commit `d2072c62ea708e7727099fab94fa28b0bcec747b`。初始阅读的 main commit 为 `7168fd0fb1c1b1ea9150cc078f82aada3d57174d`；本模板所用上述 actions 的定义与 tag 一致。两版本 documents/web 文件存在的差异只涉及本模板未使用的 `file()` 与 `fileRequest()` 定义，不涉及 get/save/file-select/jsonRequest/downloadURL。编译产物实际由 release binary v2.3.0 生成。

文件存储动作额外显式设置的 `WFFileStorageService="iCloud Drive"`、`WFShowFilePicker=false`，来自 ScPL 项目公开的 Shortcuts 原生 action schema 提取结果（是提取的第三方项目资料，不是 Apple 官方发布）：

- https://docs.scpl.dev/actions/getfile
- https://docs.scpl.dev/actions/savefile

当前实际 plist 核对：

- 每个网络 URL 是 `WFTextTokenString`：仅引用已校验并确认的 `server` 变量，加固定 `/api/service/register`、`devices`、`send` 路由；URL 中没有 Key。
- Header 的 `Authorization` 是原生 dictionary，Value 为 `Bearer ` + `apiKey` 变量附件，不是字面密钥。
- 发送正文为 `WFJSONValues` 原生 dictionary；`text` 为原生变量附件，`ttl_seconds` 是数字 item（`WFItemType=3`），不是手拼 JSON。
- 所有 `ActionOutput` 引用的 UUID 都存在；无引用的重复控制流输出 UUID 已规范化为不同 UUID，没有修改有引用的 ID。
- 主/设置均为原生 `is.workflow.actions.*`，未引入 Scriptable、第三方 App 或 Safari JavaScript。

**仍待实机验证：** iOS 对 legacy documentpicker 存储参数的迁移/识别，iCloud 路径与重复建目录，Get Type 的本地化标签，系统文件/网络/剪贴板许可交互，以及官方签名后的安装和端到端收发。编译与结构/生成字典回归检查不能替代这些结果。

## 实机反馈后的修订（2026-11-01）
用户在 iPhone 选择合法 JSON 被误报“不是连接配置”。检查生成 plist 发现 `dict['key']` 被编译成对象属性读取；现在全部使用 `is.workflow.actions.getvalueforkey`，明确 WFInput/WFDictionaryKey/Value。另发现 `--derive-uuids` 使独立控制流重用 GroupingIdentifier，已禁用并验证完整栈配对。复合减法变量右值会错误赋值，故按简化原则删除两套字节预检，依赖服务端长度限制。正则实际字节检查没有发现双转义错误。新模板需再次官方签名并在 iPhone 试运行；不能把此次生成结构测试声称为实机已修复验证。

用户后续已完成旧版 Mac 官方签名及 iPhone 安装，并运行到配置校验失败，故先前“签名/安装未验证”仅描述开发环境当时状况。修复版仍待重新签名与实机重试，收发链路尚无通过证据。
