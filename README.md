# SSClip

SSClip 是一个零第三方依赖的原生 macOS 剪贴板管理器，定位是精简、快速、键盘优先。它常驻菜单栏，历史与收藏只保存在本机，不包含网络请求或遥测。

## 功能

- 监听文本、图片和 Finder 文件复制，变化时播放提示音；文本同时保留 RTF/HTML 格式
- 点击录制全局快捷键（默认 `⌥⌘V`），支持字母、数字、符号、方向键和功能键
- 每页 10 条，按 `1…9 / 0` 直接粘贴，`⌘← / ⌘→` 翻页，方向键移动选择
- `Tab` 在剪贴板历史与收藏之间切换
- 面板内搜索、收藏、删除、纯文本粘贴快捷键均可自定义，并自动检测冲突
- `↩` 保留格式粘贴，`⇧↩` 纯文本粘贴，空格预览内容
- 支持自定义收藏夹和顺序粘贴的批量模式
- 可选登录时自动启动，并可按保存天数、最大条数自动清理历史
- 尊重密码管理器的 Concealed/Transient 标记，不记录标为敏感或临时的剪贴板
- 支持原生明暗主题、VoiceOver 标签和键盘焦点

## 系统要求

- macOS 13 或更高版本
- Xcode 16 或兼容 Swift 6 Package Manifest 的工具链

## 构建与运行

运行测试：

```bash
swift test
```

开发环境直接运行：

```bash
swift run SSClip
```

构建本地 `.app`：

```bash
./scripts/build-app.sh
open dist/SSClip.app
```

构建脚本会生成临时签名的 `dist/SSClip.app`，适合个人本机使用。正式分发需要开发者签名和 Apple 公证。

## GitHub Actions 构建

推送到 `main`、提交 Pull Request 或推送 `v*` 标签时，GitHub Actions 会在 GitHub 托管的 macOS runner 上重新测试并构建应用，不会上传开发者本地的 `dist/`。

每次成功构建都可在 [Actions](https://github.com/dandibbert/ssclip/actions) 对应运行的 Artifacts 区域下载 `SSClip-macOS`，其中包含 `SSClip-macOS.zip` 和 SHA-256 校验文件。推送版本标签（例如 `v1.0.0`）后，相同文件还会发布到 [Releases](https://github.com/dandibbert/ssclip/releases)：

```bash
git tag v1.0.0
git push origin v1.0.0
```

下载后可验证 ZIP：

```bash
shasum -a 256 -c SSClip-macOS.zip.sha256
```

自动构建的 App 使用临时签名，没有 Developer ID 签名或 Apple 公证。首次运行可能触发 Gatekeeper；可在 Finder 中右键点击 App、选择“打开”并确认。面向普通用户的无警告正式分发仍需要 Developer ID 和 Apple 公证。

## 系统权限

首次直接粘贴时，macOS 会请求“系统设置 → 隐私与安全性 → 辅助功能”权限。这项权限只用于向当前应用发送一次 `⌘V`。若不授权，选择内容仍会写入系统剪贴板，可手动粘贴。

## 隐私与本地数据

历史记录保存在 `~/Library/Application Support/SSClip/history.json`，其中包含完整文本、RTF/HTML 富文本、Finder 文件路径、收藏与文件夹关系、时间等记录信息；图片内容保存在 `Images` 子目录。目录和文件权限仅允许当前用户访问，但内容没有额外加密。

如果 `history.json` 无法解析，SSClip 会把原文件隔离为同目录下权限为 `0600` 的 `history.corrupt-*.json`，再从空历史启动。隔离文件仍可能包含完整文本、RTF/HTML、Finder 文件路径、收藏关系和时间等敏感记录；应用不会自动删除这些恢复副本，确认无需恢复后可手动删除。

SSClip 没有网络请求或遥测，并会跳过带有 Concealed/Transient 标记的敏感或临时剪贴板内容。与所有剪贴板工具一样，请根据自己的安全需求评估保存历史记录的风险。

## 项目结构

```text
Sources/SSClip/   应用源码
Tests/SSClipTests/ 自动化测试
Resources/        应用图标和 Info.plist
scripts/          本地应用打包与图标工具
```

## License

本项目采用 [MIT License](LICENSE)。
