# 轻量工程基线检查

本轮核对当前源码、锁文件、脚本、平台入口和既有验证记录。日期：2026-11-06；设备相关历史反馈保持其原日期。

## 实际运行

```bash
./scripts/check
```

| 检查 | 实际命令 | 本轮结果 |
| --- | --- | --- |
| 格式 | 项目 `dart format --output=none --set-exit-if-changed lib test integration_test test_driver` | 通过；32 个文件，0 个改动 |
| 静态分析 | `./scripts/flutterw analyze --no-pub` | 通过；No issues found |
| 普通测试 | `./scripts/flutterw test --no-pub` | 通过；47 项测试 |
| 检查入口语法 | `bash -n scripts/check` | 通过 |

完整输出保存在 [check.log](check.log)。本机 PATH 中没有独立的 dart/flutter 命令；使用 `.tooling/flutter` 中的 Flutter 3.47.9 / Dart 3.13.7 即可执行。脚本缺少 SDK 或依赖时会说明准备命令，不隐式下载、升级或改格式。

## 范围

- 没有新增依赖、CI、代码生成、框架或工作流工程。
- 原有业务、测试、平台配置、锁文件、资源及旧脚本共 158 个文件以检查前后 SHA-256 比较，未改动；变更为工程文档和新增 `scripts/check`。对照摘要见 `scope-check.json`。
- 未重构播放器、调整交互、构建或安装应用，也未重跑真实 API / 设备集成实验；这些在本轮均为 Not Tested。
- 旧的播放器、Bangumi 和迁移证据保留在相应验证子目录；不把旧证据写成本轮重新执行。
- 首次审计时本地没有提交历史，代码均未跟踪；用户随后明确授权推送到个人远端 `mayoiboshi/Orvex`。已核对远端无现有分支或标签，使用本机已有 SSH 身份进行首次基线提交；不会覆盖旧远端历史。

## 当前工程风险入口

[ARCHITECTURE](../../ARCHITECTURE.md) 中记录页面职责集中、大目录扫描、数据/缓存恢复、测试素材进正式包、发布联网与许可清单等事实；[ROADMAP](../../ROADMAP.md) 区分已实现与待办。不存在单独的“已完成全部跨平台验收”结论。
