# 平台构建入口与当前环境

本机为 Apple Silicon Mac。Flutter 与包缓存放在项目 `.tooling` 中；可通过 `ORVEX_PROXY=http://127.0.0.1:7892` 显式使用用户提供的本机代理，脚本不会把这个地址写进手机。系统原有 Java 8 保持不变。

长期目标是四平台，当前交付仍优先 iOS/iPadOS。本文只维护平台命令和工具链前提；当前能力见 [ROADMAP](ROADMAP.md)，检查结果见 [工程基线](verification/engineering-baseline/README.md)。

## 基础检查

```bash
./scripts/check
```

该入口使用项目 Dart SDK 检查四个 Dart 源码目录，再执行 analyze 和普通测试；不改格式、不安装依赖、不启动设备，也不执行联网集成测试。首次缺少 SDK 或依赖时按根 README 准备。

工程基线任务只运行上述轻量检查；后续构建/设备执行记录见验证目录，例如 [播放器控制层](verification/player-controls/README.md)。下面给出命令与限制，不代表每次任务都会运行。

## Apple 平台

Xcode 27.2、iOS 27.2 模拟器和 CocoaPods 已可用。

```bash
./scripts/flutterw run -d macos
./scripts/flutterw build ios --release --no-codesign
./scripts/flutterw devices
```

本机此前已用用户选择的个人团队完成 iPhone Release 构建、安装与部分真机验收。换机器仍需完整 Xcode、CocoaPods、设备信任/开发模式及用户自己的签名团队；本轮不改变签名身份。

模拟器原生实验只在确认目标是 iOS 模拟器后运行：

```bash
./scripts/flutterw test integration_test/native_playback_test.dart \
  -d IOS_SIMULATOR_ID --no-uninstall \
  --dart-define=ORVEX_SILENT_SIMULATOR_TEST=true
```

该脚本会自动导入生成素材，已增加 iOS 运行时模拟器断言，不能把设备 ID 换成用户 iPhone。真机用正式 `lib/main.dart` 入口和用户自备媒体；断言不替代调用前核对目标，也不授权在其他物理设备导入生成素材。

Bangumi 联网实验是另一条独立命令，脚本自身断言模拟器；代理参数仅供测试：

```bash
./scripts/flutterw test integration_test/bangumi_metadata_test.dart \
  -d IOS_SIMULATOR_ID --no-uninstall \
  --dart-define=ORVEX_BANGUMI_TEST_PROXY=127.0.0.1:7892
```

这条实验用 FakeEngine 验证元数据与界面，不验收播放/声音。模拟器无声预览、历史设备结果见 [验证状态](verification/STATUS.md)。

macOS Debug/Profile 和 Release 的出站网络授权目前都未配置。本轮联网封面验证失败，离线 UI、主题持久化和原生播放分别通过；尚未修改权限并复验联网，不能仅凭播放构建成功认定 Bangumi 联网可用。结果见 [视觉验证](verification/visual-system/README.md)。

## Android

已安装 OpenJDK 17.0.21，使用独立的 Homebrew 路径，不更改默认 Java：

`/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home`

Android SDK 尚未下载；安装等待用户确认官方许可。
官方页面：https://developer.android.com/studio

此前记录的 Apple Silicon 命令行工具（本轮未下载；恢复 Android 工作前应重新核对）：

- 下载：`https://dl.google.com/android/repository/commandlinetools-mac_arm64-15859902_latest.zip`
- SHA-256：`835b62a26162b229b441d1f6d4680383815a270809eb33522c0d480fa5002c4e`
- 计划安装路径：`.tooling/android-sdk`
- 当前固定 Flutter SDK 的默认值：compile/target API 36、min API 24；NDK `28.2.13676358`。

SDK 安装后，以下入口会选择项目 SDK、Java 17 和项目 Gradle 缓存：

```bash
ORVEX_PROXY=http://127.0.0.1:7892 ./scripts/androidw build apk --debug
ORVEX_PROXY=http://127.0.0.1:7892 ./scripts/androidw run -d ANDROID_DEVICE_ID
```

其他机器可通过 `ORVEX_JAVA_HOME`、`ORVEX_ANDROID_SDK` 指向已有工具。
这些命令还未成功执行，不构成 Android 构建或播放验收。`release` 目前沿用 debug 签名；应用主 manifest 未显式声明 INTERNET，只有 debug/profile 有声明，发布时需核验最终合并清单和联网权限。本轮不修改这些配置。

## Windows

已生成 `windows/` 工程与平台插件入口。Windows 桌面构建需要 Windows 主机，
本机未连接 Windows 环境，因此没有声称构建成功。

在 Windows 上安装匹配版本 Flutter 和 Visual Studio 的 C++ 桌面开发组件后：

```powershell
flutter pub get
flutter build windows --release
flutter run -d windows
```

SDK 目录中的当前 Flutter 为 macOS 工具，不能直接复制为 Windows SDK。
