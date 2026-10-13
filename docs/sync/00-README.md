# Kelivo 多端同步 · 交接说明（给 Codex）

这套文档描述「给 Kelivo 加多端同步」的完整方案。仓库已 clone 到 `D:\projects\bot-workspace\kelivo`（v1.3.1+80）。

## 文件

| 文件 | 内容 | 读者 |
| --- | --- | --- |
| `01-plan.md` | 主方案：现状核实、架构、数据模型、冲突策略、里程碑、测试、风险 | 你（决策）+ Codex（背景） |
| `02-api.md` | 客户端 ↔ 服务端接口契约（含服务端表结构、同步循环规范） | Codex（实现依据） |
| `03-deploy.md` | 阿里云 ECS 部署与运维（compose、Caddy、备份、升级） | 运维（你或 Codex） |
| `04-codex-tasks.md` | 按 PR 拆分的实施任务清单（目标 / 改动文件 / 验收 / 依赖） | Codex（执行清单） |

## 建议的 Codex 提示词

```
读 D:\projects\bot-workspace\kelivo-sync\ 下的 01-plan.md、02-api.md、04-codex-tasks.md，
按 04 的任务顺序实现，一次做一个任务并单独提交。
仓库在 D:\projects\bot-workspace\kelivo，遵守它的 kelivo/AGENTS.md：
- 分层生长，先做能端到端跑通的最小版本，不要加兼容垫片或投机抽象
- 优先用仓库已有依赖（drift/dio/uuid/crypto/archive）
- Drift 表只允许在末尾追加列；新表不影响现有列顺序校验
- 每个任务完成后必须通过：dart format lib test、dart analyze --fatal-infos lib test、flutter test
- 改 ARB 后跑 flutter gen-l10n 并提交生成物；改 Drift schema 后跑 dart run build_runner build 并更新 drift_schemas/
遇到方案与代码实际情况冲突时，先停下来在任务说明里写明冲突点，不要自行改变架构。
```

## 实现顺序（摘要，详见 04）

1. **PR1 本地变更日志**：新表 + 触发器 + 迁移 + 单测（不碰网络）
2. **PR2 同步核心（纯逻辑）**：记录模型、LWW 裁决、应用器、`messageOrder` 重排（可在内存库上测）
3. **PR3 传输层**：按 `02-api.md` 实现 HTTP 客户端 + 游标/令牌持久化
4. **PR4 同步引擎**：pull→apply→push 循环、退避重试、状态上报
5. **PR5 UI**：设置页「多设备同步」+ 配对（二维码生成/扫描）+ 状态与冲突提示 + 三语文案
6. **PR6 后台触发**：启动时 / 手动 / 后台周期（Android 前台服务或 WorkManager、桌面定时、iOS BGTask）
7. **PR7 服务端**：Go 实现 + Dockerfile + compose + 契约测试
8. **PR8 附件通道**（M2）、**PR9 E2EE**（M3）

## 必须先落地的两个坑

1. `messageOrder` 与 `(conversationId, groupId, version)` 是本地唯一约束，**不能参与同步**；应用远端消息后必须重排（见 `01-plan.md` §4.5）。
2. 现有 `tombstone_rows` 只记录会话删除、且 90 天裁剪；同步要求它扩展到消息/实体的删除，并由服务端永久保留删除三元组（见 `01-plan.md` §6）。

## 待确认（影响实现）

服务端语言（默认 Go）、API Key 是否同步（默认否，M3 走 E2EE）、是否需要 SSE 实时、域名与证书、ECS 规格。

## 建议的第一步

1. 先在愿望池 [IDEA-0013](https://kelivo.psycheles.top/ideas/13) 下 +1 或留一句你的方案方向（作者已标记 Clarified，说明有意向）；这能让后面提 PR 时好谈。
2. 本地先开分支实现 PR1/PR2/PR7（纯本地 + 服务端，风险最低），跑通后再接 UI 与后台。
3. 服务器先用最小规格把 `kelivo-sync` 跑起来做联调，确认手机/电脑都能连上再考虑 E2EE 与实时推送。
