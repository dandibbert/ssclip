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

## 单快捷指令修订
删除独立设置模板及其生成步骤。每次通过原生 choosefromlist 选择新鲜设备；列表固定配置入口用原生 runworkflow 调用同名主快捷指令，仅传无秘密标记 SSCLIP_REIMPORT_V2，导入后退出。旧状态只读取 version/server_url/api_key，不读取或持久化目标。当前463actions，2696项静态/fixture验证；新交互尚需实机验证。

可解析的无效版本/URL/key/注册失败提供仅异常路径出现的重导入/取消选择；使用同名self调用无秘密marker，导入成功前不写旧状态。原生HTTP或JSON解码异常不能假称已捕获。

## 多 iOS 逻辑发送端（最终覆盖前述 phone-id 设计）
按产品决定取消物理手机唯一身份：不再读取、生成或写入 phone-id，也不取设备名称。所有iOS快捷指令使用本站逻辑发送源 ios-shortcut-sender / iOS 快捷指令，register明确原生JSON boolean can_receive:false。生成plist字段 WFItemType=4、WFValue.Value=false（真实plist布尔），不是字符串。独立Bark目标负责区分各手机接收。iCloud中仅共享URL/key连接配置。最终426actions，2502项检查；正常每次只选Mac，所有异常恢复和取消保持。

最终接收目标扩展为 Mac 与已启用 Bark 的iOS。显式getvalueforkey读取transport，macos或(ios且bark)才进入列表，并按保留ID排除共享source。根据本站契约唯一can_receive=false正是此保留source，不使用脆弱布尔文本比较。Bark send仍state=pending，故成功仅说明服务端接受。最终447actions，2619检查。

最终补充显式can_receive:false过滤：原生getText(item dictionary)得到JSON，matchText匹配仅JSON布尔false。生成regex对true/false/缺失/字符串false/设备名含伪字段向量验证；生成eligibility块解释器也覆盖disabled Mac/Bark。最终457actions、2707检查。该新gate需iPhone实机验证，不能用合成JSON检查替代原生运行。

## 反复导入修订的真实导出依据
来源：https://gist.github.com/extratone/f0debc4ccc32ee1349be4e8632c2367b （Apple Frames 4 原生导出分析）。动作136及JSON4314–4318为documentpicker.open，仅WFGetFilePath=/Frames/NewFrames.json、WFFileErrorIfNotFound=false、UUID；紧随动作137设变量、138 Count Items、139条件。此模式支持本候选的modern loader + Count Items设计，但不证明用户设备已修复。用户已证实.json存在，故保留文件，不采用扩展名迁移推测。
新候选513actions、3014结构检查，并新增实际生成动作的三冷启/保存读回小解释器5测试组。新格式/版本/地址/key四项读回检查且无值反馈。

## 最终确认：实际 .txt 与旧 .json loader 不一致
用户后续实机明确文件实际后缀为 .txt，前述“exact .json存在”的初步理解已被纠正，不能再归因为未知folder根映射。最终canonical使用connection-state.txt，保留现代原生路径参数，不引入新folder/bookmark。仅精确兼容旧.json.txt/.json文件，读回只canonical；不删除旧文件。

Set Name 依据：Cherri actions/basic.cherri 的原生 setitemname(WFInput,WFName,WFDontIncludeFileExtension)，以及 https://docs.scpl.dev/actions/setname 提取的WFSetItemNameAction定义。实际生成字段WFName=connection-state.txt，WFDontIncludeFileExtension=false显式存在；save引用该命名输出。提取schema不是当前iOS运行证明。

最终531actions、3120结构检查、11持久化测试组。负fixture来自实际e4a4182c交付resource，记录完整commit与resourceSHA；不含任何用户配置。实际原生提供器与iCloud行为仍需手机验证，模型只明确测试文件名策略与生成动作控制流。

最终UX收敛：用户明确iOS只发Mac，故撤回此前Bark目标扩展。只macos并排除can_receive:false；ID仍用于不歧义选择，但单独choiceNameMap用于简短“已提交→名称”。设置成功短“连接已保存”，不声称已复制。最终526actions、3105结构检查、11持久化测试组。
