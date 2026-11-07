# iPad 首页第二轮视觉精修

截图来自 iPad 模拟器运行的 Orvex，沿用隔离的生成样片和缓存封面。横屏采用 1210 × 834 逻辑点，窄窗口采用 438 × 834 的应用视口。

| 场景 | 顶部 | 底部 |
| --- | --- | --- |
| 横屏浅色 | [顶部](landscape-light-top.png) | [底部](landscape-light-bottom.png) |
| 横屏深色 | [顶部](landscape-dark-top.png) | [底部](landscape-dark-bottom.png) |
| 窄窗口浅色 | [顶部](narrow-light-top.png) | [底部](narrow-light-bottom.png) |
| 窄窗口深色 | [顶部](narrow-dark-top.png) | [底部](narrow-dark-bottom.png) |

另见[媒体库与最近添加](landscape-light-library.png)和[模拟器布局测量](observations.json)。

- 横屏主续播卡实测约 680 × 224 点，首页导航 500 × 48 点。已核对横屏主卡与续播轨道并排、窄窗口上下排列，以及最近添加在媒体库入口之前。
- 续播轨道实测读取了本地缩略图。截图中的彩条来自模拟器测试视频本身。缺少可用帧时，缓存竖版封面仍按原比例展示。首页无实时背景模糊。
- 模拟器检查明暗主题、滚动到最后一行、最后一张海报的资料入口、四个 Tab、媒体库入口和原生续播。首页控件测试覆盖 360、438、834、1210 点宽度及双倍文字。
- `./scripts/check` 通过格式、静态分析和 140 项测试。
- 系统级旋转、分屏、台前调度、声音与真机视觉未验收。
