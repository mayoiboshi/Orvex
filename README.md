# Orvex 2.0

Flutter 本地影音应用，长期目标为 iOS、Android、macOS、Windows，目前交付优先 iOS/iPadOS。
已有本地视频、外挂字幕、断点续播、四模块首页与 Bangumi 番剧资料。具体完成程度以实际实现和设备证据为准。

## 开发入口

本项目使用本地 Flutter **3.47.9 / Dart 3.13.7**，SDK 固定提交
`c197ca5199e9ee5661e865596c9c07294dfab51c`。依赖缓存也放在项目中，不要求全局安装 Flutter。

```bash
# 初次设置，或核验已有 SDK 并恢复依赖
./scripts/bootstrap-flutter.sh

# 需要代理时由当前终端显式提供，不写进手机 App
ORVEX_PROXY=http://127.0.0.1:7892 ./scripts/flutterw pub get

# 一次基础检查：只检查格式，不自动改文件；不运行设备/联网集成测试
./scripts/check

# 查看设备、运行正式应用入口
./scripts/flutterw devices
./scripts/flutterw run -d DEVICE_ID --release --target=lib/main.dart
```

本机已配置的个人团队签名不是其他开发者的分发配置；更改签名身份需用户授权。
其他平台的工具链和限制见 [平台设置](docs/platform-setup.md)。在 Windows 上需要安装相同版本、适配 Windows 的 SDK；本仓库 bash 入口不能当作已验证的 PowerShell 方案。

## 文档入口

- [AGENTS.md](AGENTS.md)：任务分级、修改边界、代码风格、验证和汇报规范。
- [ARCHITECTURE.md](docs/ARCHITECTURE.md)：实际技术栈、模块职责、依赖与播放链路、风险。
- [DECISIONS.md](docs/DECISIONS.md)：已采用的技术选择、理由和待验证事项。
- [ROADMAP.md](docs/ROADMAP.md)：当前能力主清单、平台证据和后续任务。
- [验证状态](docs/verification/STATUS.md)：历史构建、原生实验与用户真机反馈；本轮检查见 [工程基线记录](docs/verification/engineering-baseline/README.md)。
- [首页设计](docs/home-design.md)、[Bangumi 接入](docs/bangumi-metadata.md)：对应功能的设计与实现说明。

## 验证边界

`./scripts/check` 通过不代表所有平台可以播放。当前已有 iPhone 用户自备文件验收，iPad/Android/Windows 等未执行的设备检查仍需分别验证。

物理设备始终使用用户自备视频和字幕。`integration_test/native_playback_test.dart` 会自动导入生成素材，不能直接对用户 iPhone 运行；模拟器实验有无声限制。详细命令和当前约束见 [平台设置](docs/platform-setup.md)。

素材来自项目生成或获授权依赖，中文字体 OFL 保留在 `assets/fonts/NotoSansCJK-OFL.txt`。项目级许可证及完整第三方分发清单尚未确定。
