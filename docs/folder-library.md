# 文件夹媒体库与竖屏详情页

日期：2026-11-06。本轮范围来自用户明确提出的目录/缩略图/播放列表任务与迅雷竖屏参考图；不更换 media_kit、不增加依赖、不改变用户源文件，也不接入其他数据源。能力主清单仍维护在 [ROADMAP](ROADMAP.md)。

## 结构与访问

`features/folder_library` 使用原有 Riverpod 装配和 ChangeNotifier。FolderRoot 保存授权、根目录及扫描状态，FolderEntry 保存根 ID、相对路径、目录类型、文件大小/修改时间、可用性和可选时长；播放仍使用原有 LocalMedia，新增可选 folderRoot/folderFile 稳定身份。播放进度和状态通过该身份关联现有 PlaybackHistoryStore，不复制一套进度系统。

- iOS/iPadOS：UIDocumentPicker `.folder`、`asCopy: false`，保存 minimal bookmark；每次工作恢复书签、成对 start/stopAccessingSecurityScopedResource。读取目录使用 NSFileCoordinator；原文件只读。
- macOS：NSOpenPanel 选择目录，保存带只读权限的 security-scoped bookmark；已有 user-selected.read-only 权限上增加 app-scope bookmark 权限。
- Android：最小原生 SAF 适配器使用 ACTION_OPEN_DOCUMENT_TREE 与持久读权限、DocumentsContract 枚举和 content URI；不把 URI 当绝对路径。media_kit 的 Android content URI 适配继续负责播放。Android 未具备本机 SDK，尚未构建/运行。
- Windows：复用 file_selector 目录选择，异步文件系统读取、相对路径解析与根目录边界检查；没有持久卷/文件 ID 适配，重命名识别保守。尚未在 Windows 验证。

Apple 共享实现位于 `native/apple/MediaFolderAccess.swift`，由 iOS/macOS 宿主持有；不修改自动生成的插件入口。授权失效时保留索引与历史，提供原目录重新授权和重新扫描。不会把整个目录复制到 App 中。旧的单文件“导入副本”入口继续保留。

## 扫描和兼容

递归按目录异步读取，逐步展示发现的内容，显示实际目录/视频计数，不虚构百分比。忽略隐藏项、符号链接、包目录和不支持格式；子目录错误独立记录。取消扫描保留已发现结果和有效旧索引。扫描结束后，只在已确认覆盖的路径中将消失的条目标为不可访问；读取失败的子树保留原可用状态和稳定身份。扫描不删除历史。应用启动只加载索引，不自动全盘重扫。

索引为应用支持目录内 `folder-library-v1.json`；串行写临时文件并替换，保留一份备份。主索引无法解码或根目录、条目列表结构不合法时尝试备份。恢复后的首次保存保留已用来恢复的备份，直到有有效主索引可供轮换。缓存和索引均不写入用户源目录。原有 Imports 相对身份、历史 v2 和续播键保持兼容，历史只增加可选字段，普通 URI 与导入副本的原键不变。Bangumi 只对新的文件夹媒体改用稳定身份，旧条目键保持原样。

Apple 的 documentIdentifier 与 volumeUUID 可用时、Android provider document ID 可靠时沿用文件 ID；同根目录内重命名/移动可保留进度。**不使用跨重启不可靠的 fileResourceIdentifier/inode，也不按展示标题/大小猜测移动。** 身份缺失时仅复用路径、大小、修改时间一致的记录；无法确认的移动创建新身份，保留旧历史。跨根目录移动不自动合并。提供方改变文件 ID 或复用身份的情况仍需设备验证。

## 缩略图与会话

Apple 使用 AVAssetImageGenerator 后台提取，Android 使用 MediaMetadataRetriever；不创建大量播放引擎，也不触碰当前播放会话。选择约 15% 处、最多 90 秒的帧；最长两段读取/提取等待各 15 秒（Apple），原生系统不支持的格式显示主题占位。播放内核仍是 libmpv，因此“不能提取缩略图”不代表“不能播放”。Windows 缩略图提取适配尚未实现。

只有惰性列表中已构建的项目申请预览，队列最多一个解码任务。行销毁取消排队工作；正在运行的工作最多一个，完成后只为仍有效的文件版本留缓存，不回写已销毁的行。文件 ID、根 ID、大小、修改时间与缓存版本生成键。JPEG 缓存使用磁盘最近使用顺序，限 128 MiB/2000 张；清理范围只限应用自有缩略图目录。失败有界暂存，避免滚动反复请求。视频时长随成功提取保存。

PlaybackSession 增加当前列表、索引、前后项目及默认关闭的自动下一集；所有命令仍由现有会话串行执行。选中视频时建立其所在文件夹的列表；浏览其他分组不改播放目标。历史保存根/文件 ID，再从索引恢复当前路径和列表。播放资源准备返回授权释放回调；会话在引擎释放后才释放目录作用域，过期准备结果也正确释放。后台或返回媒体库时禁止自动下一集。

## 单集导入修复（2026-11-06）

已导入单集原先因没有 FolderEntry 被直接跳过预览，现与目录视频共用单任务队列和磁盘限额。ImportedFileStore 解析当前 Documents 目录，原生 thumbnailImported 只读取 Imports 下的安全相对路径，复用现有提取器。图片可选 `.duration` 元信息随图淘汰，兼容旧缓存；加载与不可提取使用不同提示，不改变 Bangumi 海报逻辑。

导入时流式计算 SHA-256，相同大小候选用完整内容哈希核对，相同内容返回旧 LocalMedia/续播键；清理本次临时副本，旧副本和历史保留。可重建哈希索引只加速查重，不迁移旧数据。首次校验旧候选仍需读取视频，不承诺大文件零等待或零临时空间。验证见 [修复记录](verification/imported-media-fix/README.md)。

## 页面

后续已增加默认“剧集”视图：按真实名称、季/年份及来源派生分组，跨范围目录汇总分集；只有编号时尝试目录上下文。切回“文件夹”仍保留完整层级。Bangumi 自动采用返回首项，同组共享查询；手动更正/忽略作用于整组，并可被后续成员继承。组内播放使用有序分集列表，来源 URI、文件 ID 和进度不改变。实现/验证见 [剧集记录](verification/series-library/README.md)。

保留真实视频区域、原控制层、全屏、字幕/音轨和手势。竖屏使用单个滚动区域：简洁导航、16:9 播放区、媒体信息、Bangumi、播放列表、面包屑、逐层文件夹条、16:9 预览行。完整文件名放在实际“文件详情”入口；手势说明移到帮助。搜索/未播放筛选在播放页按需展开，媒体库默认显示搜索。

每条横向目录条只表示一个真实层级；根/父级返回、同级切换和定位当前视频均基于索引。视频区域在非惰性的头部保持挂载，列表惰性构建；滚动不重新创建播放引擎。继续沿用语义色、系统字体和克制的 Flutter 玻璃组件，不声称是 Apple 原生 Liquid Glass。

## 依据与验证边界

- [Apple：选择目录与递归授权](https://developer.apple.com/documentation/uikit/providing-access-to-directories)
- [Apple：NSURL 安全作用域与书签](https://developer.apple.com/documentation/Foundation/NSURL)
- [Apple：documentIdentifier](https://developer.apple.com/documentation/foundation/urlresourcevalues/documentidentifier)、[fileResourceIdentifier 的限制](https://developer.apple.com/documentation/foundation/urlresourcevalues/fileresourceidentifier)
- [Android：DocumentsContract](https://developer.android.com/reference/android/provider/DocumentsContract)、[Document ID](https://developer.android.com/reference/android/provider/DocumentsContract.Document)
- [Apple：AVAssetImageGenerator](https://developer.apple.com/documentation/avfoundation/avassetimagegenerator)

详细自动检查、原生/模拟器验证和真实截图见 [本轮验证记录](verification/folder-library/README.md)。生成视频实验只限已核对的 iOS 模拟器和本机 macOS；不代表外部 Files/iCloud 提供方授权、手机声音、真实 MKV/4K/HDR、大片库功耗或物理设备通过。
