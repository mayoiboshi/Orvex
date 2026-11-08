# 最近添加作品海报验证

| iPad 模拟器应用视口 | 浅色 | 深色 |
| --- | --- | --- |
| 宽窗口 1210 × 834 | [最近添加](landscape-light-recent.png) | [最近添加](landscape-dark-recent.png) |
| 窄窗口 438 × 834 | [最近添加](narrow-light-recent.png) | [最近添加](narrow-dark-recent.png) |

模拟器使用已缓存的 Bangumi 海报和隔离测试数据。彩条是测试视频帧。损坏海报的样本展示保持视频比例的回退图。窄窗口通过调整应用视口验证，截图覆盖区域上半部分。系统分屏和真机视觉待人工验收。

`./scripts/check` 通过格式检查、静态分析和 144 项测试。iPad 模拟器验证四种窗口和主题组合中的海报与视频框尺寸、最后一排可见性、资料入口、作品详情单集缩略图以及原生无声续播。见 [运行结果](observations.json)。
