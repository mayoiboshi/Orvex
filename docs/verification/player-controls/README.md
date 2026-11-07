# 播放器控制层与基础手势

日期：2026-11-06。沿用 media_kit 1.2.6 / media_kit_video 2.0.1 / libmpv 和既有 PlaybackSession；未更换引擎、添加依赖或改变存储格式。修改限于播放视图、少量页面接线、独立 iOS 亮度适配与相关测试。

## 操作与实现范围

- 单击视频空白处切换控制栏；播放时闲置约 3 秒渐隐，暂停默认保留，也可手动隐藏。180ms 动画只作用于控制层，视频组件不随显示状态移除。菜单、拖动及长按期间不自动隐藏；隐藏控件不参与键盘焦点和辅助功能导航。
- 顶部为标题、可用的返回入口与播放设置；中央播放/暂停；底部进度、时间、速度、静音和全屏。窄屏将音轨/字幕入口放入设置，宽屏还可从底部直接打开。点击时间可切换总时长/剩余时间。
- 移动端左/右空白区域双击 ±10 秒；中央空白区域播放时长按临时 2x。松手、取消、暂停、中断、退出视图时恢复原速度；换片不把旧速度写给新引擎。原有横滑跳转保留，进度条与按钮自行处理触摸，不同时触发背景手势。
- 进度拖动持续显示目标时间，松手只提交一次跳转；引擎进度不覆盖正在拖动的值。松手后短暂保留目标直到收到相应进度，最迟 1.5 秒退出等待；取消、后台和换片清理预览，不额外跳转。没有视频缩略图预览。
- 移动端右侧上下滑动调节播放器音量，设置内提供连续音量滑块。它不是系统音量控制。
- iOS 主屏新增左侧上下滑动亮度适配，首调保存原亮度；退出播放视图或应用失活时恢复。最低 5%，最高 100%。模拟器、Android、桌面及不支持的屏幕使用系统亮度，设置中说明降级，不提供无效亮度控件。原生失败时关闭该手势并给出反馈；iPhone 本轮整体操作已获用户通过反馈；退出/失活后的实际亮度恢复未逐项确认。
- 桌面空白处双击全屏，空格播放/暂停，方向键 ±10 秒，F 切换全屏、Esc 退出全屏。鼠标移动唤醒控制栏，不抢输入焦点；仅视频自身焦点处理快捷键，滑块、菜单、按钮、输入框保留自身行为。全屏切换防止重入并处理失败。

亮度接口参考 [Apple UIScreen.brightness](https://developer.apple.com/documentation/uikit/uiscreen/brightness)，只适配主屏；采用独立 display 通道，不修改 PlaybackEngine 契约。没有引入第二套播放器状态管理。

## 实际验证

| 检查 | 结果与证据 | 边界 |
| --- | --- | --- |
| `./scripts/check` | 格式 34 文件 0 改动；analyze 无问题；62 项测试通过，见 [check.log](check.log) | 普通测试共含 16 项控制层/亮度适配测试；测试替身不能证明真实解码和物理亮度 |
| iPhone 18 Pro 模拟器 | 原生回归通过，见 [结果](iphone-simulator-results.txt) | 显式无声模式；后续物理 iPhone 安装见下行，不等于新增真机播放反馈 |
| Orvex iPad Preview 模拟器 | 原生回归通过，见 [结果](ipad-simulator-results.txt) 与 [全屏截图](ipad-fullscreen.png) | 同为无声模式；不能证明 iPad 真机声音、亮度或多任务 |
| macOS | Debug 原生播放回归通过，含打开后直接空格播放/暂停、桌面双击全屏，见 [结果](macos-results.txt) 与 [截图](macos-fullscreen.png) | 输入焦点与方向键另有界面测试；没有人工听音验收、当前 Release 联网或性能验收 |
| iOS 真机目标 Release 与 iPhone 安装 | 未签名编译通过，见 [日志](ios-device-build.log)；随后按用户“安装到 iPhone”授权，用原团队签名正式入口，签名校验、覆盖安装及启动均成功，见 [签名构建](ios-signed-build.log) 和 [安装摘要](device-install-launch.json) | iPhone 17 Pro Max；无测试参数，未卸载、未清除用户媒体；后续用户回复“本轮验收通过，下一轮做 ui 优化”，记为整体操作 Passed；未逐项确认亮度恢复及真实系统中断 |
| Android / Windows | Not Tested | 本轮未构建或运行；不能由共享代码和平台模拟测试声称平台通过 |

界面测试覆盖自动隐藏/暂停显示、单击与双击区分、长按松手与取消、后台前后恢复、识别长按前失活、换片、拖动等待及取消、左右音量/亮度手势、亮度失败与不可用降级、设置实际命令、桌面焦点和安全区/锁定。原生回归检查实际画面推进、暂停、连续跳转、双音轨、SRT/ASS 像素、字幕去重、倍速、全屏、续播、重复中断暂停和返回四模块。

运行原生实验的命令如下；三个目标均已核对，iOS 测试还新增了模拟器运行时断言，未向物理手机导入生成素材：

```bash
./scripts/flutterw test integration_test/native_playback_test.dart \
  -d 0D043D06-A86D-44E7-A32A-B72FDCC30299 --no-pub --no-uninstall \
  --dart-define=ORVEX_SILENT_SIMULATOR_TEST=true
./scripts/flutterw test integration_test/native_playback_test.dart \
  -d 139B061B-ED02-4594-A56A-1AAC3A7AF574 --no-pub --no-uninstall \
  --dart-define=ORVEX_SILENT_SIMULATOR_TEST=true
./scripts/flutterw test integration_test/native_playback_test.dart -d macos --no-pub
```

构建仍有现有 media_kit 插件尚未采用 SPM 的提示，macOS 构建有 Pods 宏重复警告，本轮未通过修改依赖或构建规则掩盖它们。设备分支编译曾发现并修正 Swift 属性调用错误。macOS 真实视图验证发现打开视频后焦点可能仍停留在页面外层，已补上进入播放视图的焦点请求，且保留现有输入焦点；原生空格播放/暂停复验通过。原生测试的长按步骤改为中央空白区域且先播放，随后暂停并定位以继续验证已有续播行为。

## 下一步

用户确认下一轮进行播放器 UI 优化，聚焦视觉层级、间距、图标/按钮一致性与横竖屏/平板布局，沿用已验收操作逻辑；本次反馈记录不启动 UI 实现。后续仍需用用户自备视频/字幕在 iPad 真机验证，并在 iPhone 单独确认亮度恢复、来电/耳机断开等场景。真实系统事件、极小桌面窗口、长时间稳定性和功耗仍为 Not Tested；Android 亮度原生适配、系统音量控制和缩略图预览未实现。
