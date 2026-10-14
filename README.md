# 巴别回声 · Babel Echo for iOS

本地优先的 SwiftUI iPhone 会议记录应用。当前版本 **0.1.0-alpha.3**，支持 **iOS 17+**，没有第三方依赖。界面支持简体中文、日本語和 English。

## 下载与安装

在 [Releases](https://github.com/ndof0ssome-114/babelecho-ios/releases) 下载最新版及 SHA-256 校验文件。

公开附件为 **unsigned IPA（未签名安装包）**，需要使用你自己的 Apple 开发签名后安装，无法下载后直接打开安装。仓库不提供个人开发者签名、证书或设备授权文件，也不是 App Store 或 TestFlight 分发。

推荐从源码安装：

1. 在 Mac 安装支持目标 iPhone 系统的 Xcode；iOS 27 设备需要 Xcode 27 或更高版本。
2. 打开根目录的 `BabelEcho.xcodeproj`，选择 `BabelEcho` scheme。
3. 在 **Signing & Capabilities** 选择你自己的 Team，必要时设置唯一的 Bundle Identifier。
4. 连接 iPhone，启用开发者模式，选择该设备并运行。
5. 按提示允许麦克风访问；个人开发签名可能需要在「设置 → 通用 → VPN 与设备管理」中信任开发者，并定期续签。

## 功能

- 麦克风录音、暂停/继续、本地 16 kHz 单声道 WAV 保存与播放。
- 从「文件」导入音频和视频，在本机提取 WAV。
- 使用自行配置的 ASR/文本模型进行转写、增量摘要、会议纪要、翻译、问答和说话人整理。
- 按任务选择模型，手动获取模型列表，DeepSeek 官方接口的思考模式设置及用量统计。
- 原生文字选择、全文复制、历史记录与 Markdown、TXT、VTT、双语字幕、JSON 导出。
- **仅限 iOS 27 真机**：通过系统选择器授权屏幕声音采集，停止后提取 WAV；转换失败保留恢复文件。

屏幕声音模式暂存屏幕视频和系统音频，转换成功后删除临时视频。iOS 17–26 和模拟器不支持这一路径；受保护内容或禁止捕获的应用可能无法录制。屏幕声音模式目前不混入麦克风。

## 隐私

录音前需确认参与者同意。实时转写默认关闭；模型处理由你启用并发送至你配置的服务。已有转写和可用文本模型时，结束麦克风录音会自动生成纪要，录音提示与按钮会说明这一行为。API Key 存在 iOS Keychain；没有账号同步或遥测。HTTP 需要单独开启。

详见 [隐私说明](PRIVACY.md) 与 [安全说明](SECURITY.md)。

## 构建和测试

以下命令从仓库根目录运行。在默认开发工具不是 Xcode 时，先设置：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

运行完全离线的核心检查：

```sh
swift test
```

编译模拟器应用：

```sh
xcodebuild -project BabelEcho.xcodeproj -scheme BabelEcho \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/babelecho-ios-simulator \
  CODE_SIGNING_ALLOWED=NO build
```

生成不含个人签名信息的 Release IPA：

```sh
./scripts/build-unsigned.sh
```

产物位于 `dist/`。发布流程见 [docs/RELEASING.md](docs/RELEASING.md)。模拟器 UI 测试使用独立合成数据，不打开真实麦克风：

```sh
xcodebuild -project BabelEcho.xcodeproj -scheme BabelEcho \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath /private/tmp/babelecho-ios-ui \
  CODE_SIGNING_ALLOWED=NO test
```

将示例设备名替换为本机可用的模拟器。仅编译成功不代表真实设备录音正常。

## 验证状态

alpha.3 已通过 16 项离线核心检查与 5 项模拟器 UI 检查；前台系统声音录制、保存及 WAV 播放有 iOS 27 真机用户反馈验证。2026-10-13 的个人签名更新已成功安装启动，并保留此前会议。公开 Release 使用相同应用源码重新构建为未签名包。

真实云模型兼容性、麦克风信号质量、锁屏/后台录音、受保护内容和异常屏幕采集恢复仍需专门测试。详细架构和历史验证记录见 [README_AI.md](README_AI.md)。

## 许可证

软件源码采用 [Apache License 2.0](LICENSE)。品牌名称和角色图稿不随软件许可证授权用于无关品牌或独立商业用途。

---

**English:** Babel Echo is a local-first native iPhone meeting workspace. Audio and meeting documents stay on the device unless you enable processing with providers you configure. Public release IPAs are unsigned and require your own Apple signing. iOS 17+ is supported; full-display system-audio capture requires a physical iOS 27 device. See the build commands above, [privacy notice](PRIVACY.md), and [implementation guide](README_AI.md).
