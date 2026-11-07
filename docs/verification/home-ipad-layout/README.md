# iPad 首页布局精修

使用 iPad 模拟器运行 Orvex，复用隔离的 8 个生成视频、4 条观看记录和此前的 2 张 Bangumi 封面。横屏尺寸取该模拟设备的 1210 × 834 逻辑点，窄窗口用 438 × 834 的 Flutter 视口验证。截图来自应用实际渲染，未操作系统分屏或台前调度。

| 视口与主题 | 首页顶部 | 滚动到底 |
| --- | --- | --- |
| 横屏全尺寸 · 浅色 | [顶部](landscape-light-top.png) | [底部](landscape-light-bottom.png) |
| 横屏全尺寸 · 深色 | [顶部](landscape-dark-top.png) | [底部](landscape-dark-bottom.png) |
| 窄视口 · 浅色 | [顶部](narrow-light-top.png) | [底部](narrow-light-bottom.png) |
| 窄视口 · 深色 | [顶部](narrow-dark-top.png) | [底部](narrow-dark-bottom.png) |

另见[我的媒体库和最近添加](landscape-light-library.png)及[模拟器观测](observations.json)。

- `./scripts/check` 运行格式、静态分析及 140 项测试。首页用例覆盖 360、438、834、1210 点宽度、明暗主题、双倍文字、底部安全区、主卡续播、横向轨道、媒体库和最后一张海报的播放/资料操作。
- iPad 模拟器的首页集成测试覆盖两种主题下整行海报在滚动终点位于导航上方，并实际打开最后一张海报的 Bangumi 资料、切换四个 Tab、进入媒体库和原生续播。只在模拟器使用生成样片及无声模式。
- 尝试切换模拟器系统方向时，模拟器未响应横屏请求，本轮以完整横屏尺寸的视口验收。真实系统旋转、Split View、台前调度、声音和滚动帧率未验收。
