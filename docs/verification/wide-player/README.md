# 宽窗口播放与右侧列表

日期：2026-11-06。

## 实际改动

空间足够的 iPad/macOS/Windows 播放详情页增加宽屏切换，入口在播放器底栏、全屏按钮前。窄屏模式将原播放列表放到右侧，左侧保留视频和资料；宽屏模式回到原来的上下布局。全屏仍是独立操作，没有更换引擎、修改解码/字幕/存储或引入依赖。

可用内容宽度至少 1000 逻辑点，右侧列表 320–360 点；iPad 还检查显示屏短边至少 600 点，iPhone 不出现入口。窄窗口自动回退上下布局，恢复宽度后沿用本次选择。本轮不持久保存宽屏偏好。列表复用 FolderBrowser，支持搜索、筛选、定位、目录/同剧集切换和点击播放；布局切换保留其状态，返回宽屏时滚动到顶部以露出视频。非全屏视频子树用稳定键保留，避免布局切换重建控制层或播放器实例。

## 验证结果

- `./scripts/check` 通过：格式、静态分析、132 项测试，见 [检查记录](check.log)。新增界面回归验证明暗主题、布局几何、筛选保留、缩小/恢复窗口、原播放进度和控制层不变、右侧真实选集动作。已有控制栏、手势、字幕、导航测试保留。
- iPad iOS 27.2 模拟器原生 libmpv 实验通过，见 [运行日志](ipad-native.log) 和 [结果](ipad-observations.json)：侧栏与宽屏的 16:9 视频分别约 798×449、1170×658；切换、缩放、全屏往返期间引擎创建数始终 1，外挂 ASS 轨道保持；播放中切换后进度继续推进，右侧点击第二集才创建第二个会话引擎。右侧列表滚动不移动左侧视频。明暗主题截图无捕获到的布局异常。
- iPhone iOS 27.2 模拟器回归通过，见 [日志](iphone-native.log) 和 [结果](iphone-observations.json)：明暗、横向窄窗口及全屏仍无宽屏入口，原生播放与外挂字幕轨道保持、进度继续推进。
- macOS 正式入口 Debug 构建通过，见 [构建记录](macos-build.log)。未用生成视频在物理 Mac 运行播放实验，也没有将构建通过写成桌面完整体验验收。
- 上述原生实验在写入生成素材前断言 iOS 模拟器身份；明确无声，不涉及用户片源或真机自动导入。

iPad 横向和小窗口几何是 Flutter 测试视口 1210×834、600×480 的适配验证，**不是系统级分屏、Stage Manager 或物理设备旋转验收**。真实声音、真实多任务、性能/功耗及 Windows 原生构建运行本轮 Not Tested。构建、安装成功不等于真机功能验收。

## 运行截图

使用生成的模拟器样片，不是设计稿，也不是用户视频。

- [窄屏右侧列表 · 深色](ipad-side-dark.png)
- [窄屏右侧列表 · 浅色](ipad-side-light.png)
- [宽屏原布局 · 深色](ipad-wide-dark.png)
- [宽屏原布局 · 浅色](ipad-wide-light.png)
- [小窗口回退](ipad-small-window-fallback.png)
- [全屏](ipad-fullscreen.png)
- [侧栏切换下一集](ipad-side-selected-next.png)

## 重现

```sh
./scripts/check
./scripts/flutterw test integration_test/wide_player_test.dart \
  -d 139B061B-ED02-4594-A56A-1AAC3A7AF574 --no-pub --no-uninstall \
  --dart-define=ORVEX_SILENT_SIMULATOR_TEST=true
./scripts/flutterw test integration_test/wide_player_test.dart \
  -d 0D043D06-A86D-44E7-A32A-B72FDCC30299 --no-pub --no-uninstall \
  --dart-define=ORVEX_SILENT_SIMULATOR_TEST=true
```

设备 ID 必须核对为模拟器，不可改成物理设备运行生成素材实验。

## 正式包与真机下发

iOS 正式 `lib/main.dart` Release 已构建并验证签名，沿用原团队及 bundle ID，两台用户设备均包含在描述文件中；没有模拟器实验或代理参数，见 [构建核对](build-verification.json) 和 [构建日志](signed-build.log)。

用户确认连接、解锁后，已将本轮宽屏版本覆盖安装到 iPhone 17 Pro Max 与 iPad Pro 2022，并分别启动成功。未卸载、清空数据或导入生成素材。见 [下发摘要](device-install-launch.json)；宽屏功能的实际真机操作效果仍待用户验收。

连接列表最初记录 `tunnelState: disconnected`，本次限时安装命令仍成功建立连接并完成安装；该字段表示当前隧道状态，不能单独作为设备完全离线的依据。
