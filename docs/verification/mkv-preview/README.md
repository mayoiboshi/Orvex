# MKV 预览补充与设备清理事件

日期：2026-11-06。此前“已导入”接通预览后，用户反馈物理 iPad 仍无缩略图。读取 App 内文件清单确认两份文件为 MKV，原系统提取器无法处理；不是根据 MP4 模拟器通过推断真机兼容。

## 已采用的修复

- Apple 仍先尝试系统提帧。明确的解码失败才调用已有 media_kit/libmpv；权限/路径拒绝不触发补充。
- 原单任务缓存队列持有一个短时 Player/VideoController，没有可见 Video 控件；关闭音轨和字幕，按时长选择位置、短时解码、取得实际 JPEG 后释放。不进入 PlaybackSession，不写播放进度，不设置模拟器 null 音频标志。
- 原图 JPEG 可能保留视频分辨率；列表仍以 cacheWidth 480 解码，磁盘总量沿用 128 MiB/2000 张限制。没有声称验证 4K/HDR、所有编码或长期功耗。
- 最多 100 条 thumbnail-results-v1.json 只保存哈希键、状态、后端、失败分类和时间，便于实际设备排查；不保存原文件名、路径或视频内容。

方法依据：[mpv 的截图命令说明](https://github.com/mpv-player/mpv/blob/master/DOCS/man/input.rst)、[截图当前帧实现](https://github.com/mpv-player/mpv/blob/master/player/screenshot.c)，以及仓库锁定的 media_kit/media_kit_video 源码。没有引入依赖或更换主播放引擎。

## 验证事实

- 单元测试覆盖：仅解码失败触发补充，权限拒绝不调用补充；原有缓存版本、重试、取消与限额检查保留。
- iPad 模拟器使用真实 Matroska/H.264 文件（160×90、3 秒、无音频），不是更改 MP4 扩展名；检查原生失败分类、libmpv 后端、实际图像蓝色像素、时长及可解码图像。见 [日志](ipad-simulator.log)。实验有物理 iOS 设备阻止断言。
- 用户在物理 iPad 打开媒体库后，两个真实 MKV 的状态均为 ready、后端均为 libmpv，原生失败分类均为 thumbnail_unavailable；设备上写出两张约 693 KB JPEG。随后用户确认“现在缩略图已经有了”。[脱敏摘要](physical-preview-summary.json) 不含视频或截图。
- 无输出/一直暂停的探索方案没有帧，缩放过滤器探索也未成功，均未作为交付路径；最终只采用实际通过的解码路径。新剧集功能后的完整检查和正式构建见 [当前记录](../series-library/README.md)。

## 必须保留的清理事件记录

用户授权删除两个 App 内导入副本。代理错误使用 `devicectl copy to --remove-existing-content true`，以为 `--destination` 将清理限定在两个子目录；实际清空了整个 appDataContainer，目录授权索引和缓存也丢失。代理已当场向用户说明并道歉，停止该操作；用户表示可接受，原视频位于其他本机文件夹，并明确取消恢复、不要保留偏好备份，改为重新导入及实现剧集归类。

已删除本次准备的临时偏好备份，不再恢复或继续清理。原始媒体所在的外部文件夹没有被操作。此事件不能描述为“成功完成局部删除”或“所有 App 数据保留”；AGENTS.md 已禁止用该复制选项进行局部清理。后续安装只覆盖 App，不卸载、不调用数据清空参数；用户重新选目录后重建索引。
