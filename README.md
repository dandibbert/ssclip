# SSClip

SSClip 是一个零第三方依赖的原生 macOS 剪贴板管理器，定位是精简、快速、键盘优先。它常驻菜单栏，历史与收藏只保存在本机，不包含遥测；唯一的网络请求是向 GitHub Releases 检查更新。

## 功能

- 监听文本、图片和 Finder 文件复制，变化时播放提示音；文本同时保留 RTF/HTML 格式
- 点击录制全局快捷键（默认 `⌥⌘V`），支持字母、数字、符号、方向键和功能键
- 每页 10 条，按 `1…9 / 0` 直接粘贴，`⌘← / ⌘→` 翻页，方向键移动选择
- `Tab` 在剪贴板历史与收藏之间切换
- 面板内搜索、收藏、删除、纯文本粘贴快捷键均可自定义，并自动检测冲突
- `↩` 保留格式粘贴，`⇧↩` 纯文本粘贴，空格预览内容
- 支持自定义收藏夹和顺序粘贴的批量模式
- 可选登录时自动启动，并可按保存天数、最大条数自动清理历史
- 应用内更新：每天自动检查一次 GitHub Releases（可在设置中关闭），也可在菜单栏或设置里手动“检查更新”；确认后自动下载、校验签名、替换并重新打开
- 面板内和菜单栏中按 `⌘,` 打开设置
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

推送到 `main` 或提交 Pull Request 时，GitHub Actions 会在 GitHub 托管的 macOS runner 上测试，并用 `scripts/package.sh` 打出临时签名的 DMG 和 ZIP，作为 `SSClip-macOS` Artifact 保留 14 天。这些包只用于检查，不会发布。

## 发布

正式版本由 `dandibbert/mac-build-hub` 的 `SSClip macOS build` 工作流在 M1 构建机上构建：用个人证书签名，调用同一个 `scripts/package.sh`，再把 `SSClip-<版本>.dmg`、`.zip` 和 `.sha256` 发布为本仓库的 `v<版本>` release（版本号为 `1.0.<构建序号>`）。应用内更新读取的就是最新的这个 release。

```bash
gh workflow run ssclip-macos.yml -R dandibbert/mac-build-hub -f source_sha=<完整 commit SHA>
```

下载后可验证：

```bash
shasum -a 256 -c SSClip-<版本>.sha256
```

App 没有 Developer ID 签名或 Apple 公证。首次运行可能触发 Gatekeeper；可在 Finder 中右键点击 App、选择“打开”并确认。之后的版本都用同一张证书签名，应用内更新只接受与当前 App 签名一致的新版本，辅助功能授权也会保留。

## 系统权限

首次直接粘贴时，macOS 会请求“系统设置 → 隐私与安全性 → 辅助功能”权限。这项权限只用于向当前应用发送一次 `⌘V`。若不授权，选择内容仍会写入系统剪贴板，可手动粘贴。

## 隐私与本地数据

历史记录保存在 `~/Library/Application Support/SSClip/history.json`，其中包含完整文本、RTF/HTML 富文本、Finder 文件路径、收藏与文件夹关系、时间等记录信息；图片内容保存在 `Images` 子目录。目录和文件权限仅允许当前用户访问，但内容没有额外加密。

如果 `history.json` 无法解析，SSClip 会把原文件隔离为同目录下权限为 `0600` 的 `history.corrupt-*.json`，再从空历史启动。隔离文件仍可能包含完整文本、RTF/HTML、Finder 文件路径、收藏关系和时间等敏感记录；应用不会自动删除这些恢复副本，确认无需恢复后可手动删除。

SSClip 没有遥测，除检查和下载更新（只访问 GitHub）外不发出网络请求，并会跳过带有 Concealed/Transient 标记的敏感或临时剪贴板内容。与所有剪贴板工具一样，请根据自己的安全需求评估保存历史记录的风险。

## 项目结构

```text
Sources/SSClip/   应用源码
Tests/SSClipTests/ 自动化测试
Resources/        应用图标和 Info.plist
scripts/          本地应用打包、发布打包与图标工具
```

## License

本项目采用 [MIT License](LICENSE)。
