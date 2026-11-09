# bangumi-data 本地备用匹配

Orvex 随应用附带 bangumi-data 及其贡献者发布的 **0.3.235**，对应提交 `d5f56180c0c71fbeb24bd1914eb04c75f2f358fa`。许可为 [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)。应用内在「设置 → 关于 → 数据来源」列出署名、项目、许可与转换说明。[上游项目](https://github.com/bangumi-data/bangumi-data)

- 资产为 8,928 条作品、2,135,937 字节。
- 原始发布数据 SHA-256 为 `f8f02b81690d7545e4ef9a7f9ace7eb05407c8bbc0a4f32e2aa63d10217feb85`。
- 应用内资产 SHA-256 为 `8ea4b836d0feb83eebb7ec5527fe05375cbf04d8b13448616faffa201234d8a1`。
- 发布包完整性、来源与数据条目数见 [固定版本清单](../../../assets/metadata/bangumi-data-manifest.json)。

需要更新时，在仓库根目录运行 `python3 scripts/update-bangumi-data.py 0.3.235`，或传入经审查的其他固定版本。脚本验证 npm 发布包，保留原名、翻译/别名、原始类型、放送起始时间和带站点命名空间的资讯 ID，转成紧凑 JSON。常规构建直接使用提交的资产。

## 拉丁字母标题补充

从 `cedya77/anime-offline-database` 2026-44 固定发布版提取标准拉丁字母标题。生成时要求现有 AniList、MyAnimeList、AniDB ID 至少两项指向同一记录，且其他已有 ID 无冲突，作品类型和首播年份一致。重复 Bangumi ID、无法验证的类型或年份跳过。共补入 6,213 条，`249382` 字节，SHA-256 `fe8a687555e3e8c5b9b1791222786d91cecf4f4015dd0d8ab20b3cb25125d13f`。原 bangumi-data 资产和校验值沿用上游快照。`Sōsō no Furīren` 等已核对的个别拼写仍可直接查找。[补充数据发布版](https://github.com/cedya77/anime-offline-database/releases/tag/2026-44) · [AniList 条目](https://anilist.co/anime/154587/Sousou-no-Frieren/)

补充资产作为独立派生表随应用分发，保留 ODbL 1.0 和 DbCL 1.0 许可及原署名。更新时运行 `python3 scripts/update-romanized-aliases.py`，需维护机安装 `zstd`。固定发布版与校验值在脚本内。更新资产后同步提高 `romanizedAliasRevision`，让旧版尚未命中或待确认的本地条目重查一次。已匹配、手动忽略和人工关联不参与这一轮重查。运行时索引不访问该发布网站。[派生表下载](https://raw.githubusercontent.com/mayoiboshi/Orvex/main/assets/metadata/romanized-aliases.json) · [完整许可](../../../assets/metadata/romanized-aliases-LICENSE.txt)

本轮 192 项测试通过。真实资产验证多部番剧的新增拉丁字母标题和同名不同季，缓存测试验证旧版未命中只重查一次且保留已有人工关联。iPad 模拟器在空缓存且模拟离线时，导入 `[LPSub] Meitantei Conan [01][AVC AAC][1080p][JPSC].mp4`，成功关联并播放。调试进程测得两份资产合并初始化约 1,033 ms，2,000 次热查询约 45 ms，RSS 差值约 +54.4 MiB。RSS 为单次调试进程测量，包含 Dart 运行时开销。

## 行为

- 成功的在线搜索仍沿用现有匹配顺序。已存关联、缓存和人工更正继续使用同一份资料文件。新字段读旧记录时有兼容默认值。
- 本机无非回环、非链路本地网络接口，或在线搜索遇到连接失败、超时、HTTP 408 或 5xx 时，可以回退到本地。探测只读取本机网络接口。服务故障后复用 60 秒结果，明确缺少接口复用 2 秒。人工搜索和主动重试可立即重试线上。在线空结果、限流和鉴权分别保留原有语义。
- 首次本地查询在后台 isolate 校验并建索引，并发共享同一次初始化。保守的精确名称证据可自动关联。模糊前缀、同名、季/版本冲突走待确认。没有本地候选或数据资源错误会分别报告。
- 有可靠的 Bangumi ID 时，本地和在线结果使用同一作品身份及封面缓存。缺少 Bangumi ID 时使用本地命名空间内的稳定键。相同 ID 的已有资料优先补充到本地结果。片名中的集号不用于生成官方单集资料。
- 从番剧资料面板可以手动搜索本地索引，也可以按已关联的 Bangumi ID 补全。补全保留人工选择与旧的有效字段，并校验关联仍未变化。关闭自动匹配会取消自动队列，关闭离线备用只停用自动回退，显式本地搜索仍可使用。

## 验证

`./scripts/check` 格式、静态分析和 191 项测试通过。测试包含真实资产、缺损资源、空结果、歧义、失败回退、批量退避、取消、缓存及人工选择保留、同 ID 补全。iPad 模拟器从空资料存储和空测试偏好开始，模拟明确离线，验证了真实资产匹配、设置开关、署名入口及本地视频播放。模拟器使用无声模式。

| 运行环境 | 首次加载和建索引 | 2,000 次热查询 | 初始化前后进程 RSS 差值 |
| --- | ---: | ---: | ---: |
| 本机 Flutter 测试 | 500 ms | 36.6 ms | +49.3 MiB |
| iPad Pro 11 英寸模拟器，iOS 27.2 | 819 ms | 26.6 ms | +73.4 MiB |

时间包含资产读取、校验、解码和建索引。查询测试混合精确匹配和前缀检索，未计入网络请求和资料写盘。RSS 为调试进程测量值，包含 Dart 和 isolate 开销，不能据此推断发布版的索引常驻内存。物理设备网络切换、真实大批量滚动帧率、声音及其他平台本轮未测。
