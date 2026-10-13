# Kelivo 多端同步 · 实施方案（v1 草案）

> 交付对象：本方案给 Codex（或任何实现者）按任务落地。
> 仓库：`D:\projects\bot-workspace\kelivo`（shallow clone，v1.3.1+80，分支 master，HEAD `4742d2e`）
> 目标形态：手机（Android/iOS）与电脑（Windows/macOS/Linux）之间**双向增量同步**，数据落在用户自己的服务器上。

---

## 0. 一页摘要

- **要解决的问题**：Kelivo 官方没有账号体系与多端同步（愿望池 IDEA-0013「多端消息同步」仅有 157 个 +1，状态 Clarified，无实现）。
- **好消息**：schema v3 已经为同步埋好地基（见 §1），所以不需要重做数据层，只需要补「变更追踪 → 传输 → 服务端 → 冲突裁决 → 应用」这一段。
- **方案**：客户端新增同步引擎（挂在现有 Drift 库上，触发器记录本地变更）+ 自建轻量同步服务（Go 单二进制 + SQLite，Docker 跑在用户的阿里云 ECS）+ 内容寻址的附件存储。
- **分期**：M1 对话/消息双向同步（端到端最小闭环）→ M2 其余实体 + 附件 + 后台自动同步 → M3 实时通知 + 冲突 UI + 端到端加密 → M4 上游化（可选）。
- **工程约束**：遵守 `kelivo/AGENTS.md`——分层生长、不做兼容垫片、列只追加、`dart format` + `dart analyze --fatal-infos` + `flutter test` 三关必过。

---

## 1. 现状核实（已读代码，标注来源）

| 能力 | 现状 | 来源 |
| --- | --- | --- |
| 实体主键 | 几乎全是 `TextColumn id` + `Uuid().v4()`，跨设备天然不冲突 | `lib/core/database/app_database.dart:38,102,409,451,465,483`；`lib/core/models/conversation.dart:99`；`lib/core/models/chat_message.dart:161` |
| 消息更新时间 | 已有 `updatedAt`，注释明写「in support of sync/LWW」，插入为 null，读取语义 `COALESCE(updated_at, timestamp)` | `lib/core/database/app_database.dart:149-155` |
| 会话更新时间 | 已有 `updatedAt`（并有 `idx_conversations_updated_at` 索引） | `lib/core/database/app_database.dart:30-43` |
| 删除日志 | 已有 `tombstone_rows(scope, entity_id, deleted_at, payload)`，注释「written so multi-device sync can propagate deletes」；**目前只写 `scope='conversation'`**，保留 90 天后裁剪 | `lib/core/database/app_database.dart:667-690`；`lib/core/database/chat_database_repository.dart:6257-6293` |
| 扩展实体 | 已有 `extension_entity_rows(kind,id,sort_order,owner_id,payload,updated_at)`，新实体类型不必加表 | `lib/core/database/app_database.dart:692-723` |
| 设备身份 | 已有 `installationId`（每安装一个，receipt 文件）+ `databaseId`（跟随数据库文件，恢复备份会带过来） | `lib/core/database/database_installation_gate.dart:187-238` |
| 备份/恢复 | 已有整包 zip + WebDAV/S3 + 本地快照 + 覆盖/合并两种恢复模式；有完整的 staging/cutover/lease/receipt 管线 | `lib/core/models/backup.dart`、`lib/core/services/backup/`、`lib/core/database/business_settings_merger.dart` |
| 数据库结构 | **单库单文件**：`kelivo.db` 一个 `AppDatabase`（chat 与 business 同库，无跨库事务问题），schema v3 | `app_database.dart:761,769`；`chat_database_gateway.dart:87-108` |
| 时间戳覆盖 | 29 张表里 **20 张**有 `updated_at`，写入路径统一在写时打点；**9 张没有**（`conversation_mcp_server_rows`、`message_asset_rows`、`message_prompt_rows`、`asset_rows`、`chat_storage_meta_rows` 等） | `app_database.dart` 各表定义；见 §4.4 |
| 批写语义 | `BusinessRepository.replaceEntities` 是**全删全插**、`_replacePreferences` 直接 `DELETE FROM preference_rows` → 批量写入会把整表 `updated_at` 刷成同一个 now，**光靠时间戳游标不可靠** | `business_repository.dart:300-309,459-469` |
| 业务实体 id | 多数 UUIDv4；但**旧数据**缺失 id 时由 `sha256(sourceKey + 列表下标 + payload)` 合成 → 列表重排或内容微改就换 id，产生"删除+新增" | `business_settings_router.dart:1277-1286`；`business_preferences.dart:195-265` |
| 删除语义 | **无软删除列**，除会话墓碑外一律物理删除；助手/世界书/记忆等的删除**目前不写墓碑** | `app_database.dart:667-690`；各删除路径 |
| 流式中间态 | 消息有 `is_streaming` 部分索引与 `active_streaming_ids` 元数据，流式中的行是半成品 | `app_database.dart:97-100`；`chat_database_repository.dart:8307` |
| 影子索引 | `timeline_*`（4 表 8 触发器，可丢弃重建）与 `message_search_fts`（FTS5+6 触发器）不属于 schema，但导入/合并后必须重建 | `message_timeline_index.dart:22-35,176-249`；`chat_database_repository.dart:4105-4253` |
| 附件 | 数据库只存路径与元数据；`assetId = 'asset_$sha256'`、`content_hash` 唯一 → 内容寻址天然可用，但 `path` 是**设备本地路径**，跨设备必须重写 | `chat_service.dart:2231-2234`；`app_database.dart:266-293` |
| 网络与工具库 | `dio` 5.9、`http`、`crypto`/`hashlib`、`uuid`、`archive`、`pretty_qr_code` + `mobile_scanner`（配对用）、`drift` 2.34 + `sqlite3` | `pubspec.yaml` |
| 行级变更观察 | 有 `chat_database_observer.dart`（Drift isolate 的查询/命令统计层），**不是**业务变更订阅 | `lib/core/database/chat_database_observer.dart:1-30` |
| 服务端 / 账号 / 同步游标 | **没有**（本方案要新增） | 全仓库无相关实现 |

结论：**核心数据结构（UUID 主键、UTC 微秒时间戳、单库单文件）已经适合同步**，但数据层仍需三处硬改动：① 新增变更日志表与同步状态；② 把墓碑从「只有会话」扩展到所有同步实体（否则删除无法传播）；③ 固化旧数据里合成出来的业务 id（§4.6）。其余工作量在「传输协议 + 服务端 + 应用器 + 冲突裁决」。

---

## 2. 目标与非目标

**目标**
1. 对话与消息在两台设备之间双向、增量、可离线同步；删除能传播。
2. 助手、世界书、记忆、快捷短语、MCP/搜索服务配置等业务实体可同步（M2）。
3. 冲突有确定规则、可解释、可恢复；不静默丢数据。
4. 数据只落在用户自己的服务器；默认不把 API Key 交给服务端。
5. 断网可用：本地永远是第一写入点，同步是后台收敛过程。

**非目标（本期不做）**
- 多人协作 / 会话共享 / 跨账号；聊天室实时协同编辑。
- 手机与电脑点对点直连（愿望池原话含"局域网"，但服务端方案更容易做成可靠产品；P2P 留作后续可选传输层）。
- 把 Kelivo 变成服务端应用（渲染仍在本机）。
- 同步沙盒文件系统、工作区目录、日志、缓存、临时对话。

---

## 3. 总体架构

```
┌──────────────── 设备 A（手机） ────────────────┐
│ Drift(SQLite) ← 同步引擎 ─→ WorkManager/BGTask │
└───────────────┬────────────────────────────────┘
                │ HTTPS + JSON（增量变更、幂等）
┌───────────────▼────────────────────────────────┐
│ kelivo-sync（Go 单二进制 + SQLite WAL，Docker） │
│  设备/令牌 · 变更序列(serverSeq) · 冲突裁决     │
│  附件内容寻址存储（本地卷，可选接 OSS）         │
└───────────────▲────────────────────────────────┘
                │
┌───────────────┴────────────────────────────────┐
│ 设备 B（Windows/macOS/Linux 桌面端）            │
│ Drift(SQLite) ← 同步引擎 ─→ 定时器/托盘常驻     │
└────────────────────────────────────────────────┘
```

- **服务端只做三件事**：认证设备、保存变更序列、裁决冲突。不做业务解释、不跑模型、不解析附件内容。
- **客户端是权威写入点**：所有本地写入照旧写 Drift，触发器顺手记一条变更日志；同步只是把日志推上去、把远端变更拉下来应用。

---

## 4. 数据与记录模型

### 4.1 同步记录（wire record）

```jsonc
{
  "kind": "message",          // 实体类型（见 4.2）
  "id": "uuid-v4",            // 本地主键
  "updatedAt": 1791859673443000, // 微秒 UTC，LWW 依据；消息取 COALESCE(updated_at, timestamp)
  "deleted": false,
  "originDevice": "installation-uuid",
  "payload": { ... }          // 该实体的 JSON 形态（见 4.3）
}
```

统一规则：**id 全局唯一、updatedAt 为 LWW 依据、删除用 tombstone 表达、payload 是幂等的整行快照**（不是 diff，落败版本不会被半应用）。

### 4.2 同步范围

| kind | 本地来源 | M1 | 备注 |
| --- | --- | --- | --- |
| `conversation` | `conversation_rows` | ✅ | 含标题、置顶、模型覆盖、extras |
| `message` | `message_rows` + `message_part_rows` + `message_prompt_rows` + `message_asset_rows` | ✅ | 消息本体、parts（思考/工具调用/图片/文件引用）、请求快照、附件关联一起走；**`is_streaming=1` 的行先跳过**，流结束再同步 |
| `tombstone` | `tombstone_rows` | ✅ | 删除意图，独立于记录传输 |
| `assistant` | `assistant_rows` | M2 | 提示词、参数、绑定关系 |
| `worldbook` | `world_book_rows` | M2 | |
| `memory` | `assistant_memory_rows`（旧）+ `memory_entry_rows` + `user_profile_field_rows`（新） | M2 | 记忆条目与用户画像；追加型，冲突保留双方 |
| `quickPhrase` / `searchService` / `ttsService` / `mcpServer` / `instructionInjection` / `assistantTag` / `providerGroup` | 各自表 | M2 | 纯配置，LWW 即可 |
| `workspace` / `skill` | `extension_entity_rows`（kind 区分） | M2 | 注意工作区含**本机路径**，需按 `backup_portability.dart:22-39` 的规则剥离 `hostPath` 等设备字段 |
| `provider` | `provider_rows`（主键是 `provider_key`） | ⚠️ | **默认只同步非密钥字段**；密钥见 §7 |
| `asset` | `asset_rows` + 磁盘文件 | M2 | 内容寻址（`asset_$sha256`），二进制走 object 通道；**`path` 字段本地重写，不同步** |
| 不同步 | 沙盒/工作区文件、日志、诊断、缓存、临时对话、`preference_rows` 里 `BackupPortability.devicePreferenceKeys` 列出的键（含定时任务 `desktop_scheduled_tasks_v1`）、设备本地路径与代理设置 | — | 明确白名单，避免把设备相关状态带过去 |

### 4.3 payload 形态

payload 直接复用现有模型的 `toJson()`（备份导出已经在用同一批序列化），保证「备份能还原的，同步就能应用」：会话 `conversation.dart:161`、消息 `chat_message.dart:356`、parts `message_part.dart` 均有 `toJson`/`fromJson`。实现时优先复用这些映射，而不是新写一套。
供应商要特别处理：`provider_rows.payload` 里 `apiKeys`、`oauthCredentials`（`business_settings_router.dart:579,1001-1058`）属于密钥，默认**不进同步 payload**。

### 4.4 本地变更追踪（新增）

新增一张本地表（列只追加、新表不影响 `ChatDatabaseRepository` 的列顺序校验）：

```sql
CREATE TABLE sync_change_log (
  local_seq   INTEGER PRIMARY KEY AUTOINCREMENT,
  kind        TEXT NOT NULL,
  entity_id   TEXT NOT NULL,
  op          TEXT NOT NULL,             -- insert | update | delete
  updated_at  INTEGER NOT NULL,          -- 微秒 UTC
  device_id   TEXT NOT NULL,
  pushed      INTEGER NOT NULL DEFAULT 0,
  pushed_seq  INTEGER                      -- 服务端返回的 serverSeq
);
CREATE INDEX idx_sync_change_log_pending ON sync_change_log(pushed, local_seq);
```

写入方式（二选一，推荐 A）：

- **A. SQLite 触发器**（推荐）：在 schema 迁移里对纳入同步的表建 `AFTER INSERT/UPDATE/DELETE` 触发器，写 `sync_change_log`。优点：覆盖所有写路径（包括导入器、迁移、批量脚本、`replaceEntities` 的全删全插），不会漏；缺点：触发器里要写各表 `updated_at` 的取值逻辑（消息为 `COALESCE(new.updated_at, new.timestamp)`）。
- **B. 仓库层 hook**：在 `ChatDatabaseRepository` / `BusinessRepository` 的写方法里插入记账。改动面大、易漏，仅在触发器方案在某个平台受限时退回。

**为什么不能只扫 `updated_at`**（这决定了选 A）：
1. 29 张表里有 9 张根本没有 `updated_at`（含可变的 `conversation_mcp_server_rows`、`message_asset_rows`、`message_prompt_rows`）。
2. `BusinessRepository.replaceEntities` 是全删全插、`_replacePreferences` 整表 DELETE，批量写入会把 `updated_at` 刷成同一个 now，时间粒度无法区分变更。
3. 业务实体删除是物理删除，没有墓碑就无从产生同步记录——触发器能直接观察到 DELETE。
4. 旧数据里消息的 `updated_at` 为 NULL（迁移不回填），任何时间戳查询都必须写 `COALESCE(updated_at, timestamp)`。

**迁移注意事项**（照仓库现有约定）：
- 新表/新列只允许追加；`chat_database_repository.dart:862-1007` 的权威列顺序清单与 `drift_schemas/app_database/drift_schema_v4.json` 快照必须一起更新（`dart run build_runner build` + drift schema 导出）。
- `onUpgrade` 里**索引不会自动创建**，触发器与新索引都要显式 `m.create` / `customStatement`（现有注释见 `app_database.dart:930-943`）。
- 触发器与被删表同生命周期：`clearAllData` 与覆盖式恢复会清表，触发器需能容忍（幂等 INSERT）。

同时新增同步状态（可放 `chat_storage_meta_rows` 或独立表）：
`sync_cursor`（最后应用的 serverSeq）、`sync_device_id`、`sync_server_url`、`sync_token`（放 secrets，见 §7）。

### 4.5 消息排序与流式中间态（关键坑）

`message_rows` 有唯一约束 `{conversationId, messageOrder}` 与 `{conversationId, groupId, version}`，并且有一条**严格递增校验**，违反会抛 `StateError('conversation_message_order')`（`chat_database_repository.dart:5815-5824`）。

- **`messageOrder` 是设备内稠密整数，不参与同步**：应用远端消息后按 `(timestamp, id)` 重新分配；`version` 冲突时按 `(groupId, version)` 递推重排。否则两台设备同时在同一会话追加消息必然撞唯一约束。
- **重排要小心影子索引**：批量 `UPDATE message_order` 会触发 `timeline_*` 的 8 个触发器（`message_timeline_index.dart:236-248`）。做法：应用一批变更时先把该会话的 timeline 索引丢弃（`discardStatements`，`message_timeline_index.dart:22-35`），重排后让它在下次打开会话时按需重建。
- **FTS 索引同理**：`message_search_fts`（FTS5 + 6 触发器）不属于 schema，导入/合并后可 DROP 重建（`chat_database_repository.dart:4105-4125`），否则搜索会召回已删除内容。
- **流式半成品不同步**：`is_streaming=1` 的消息等生成结束、`updated_at` 落定后再进同步队列；`active_streaming_ids` 元数据（`chat_database_repository.dart:8307`）只在本机有效，不参与同步。
- **分支/版本**：`group_id`、`version`、`version_selections_json`、`truncate_index` 一起同步（它们决定"用户看到哪一条"），冲突时以 `version_selections_json` 的 updatedAt（即会话 updatedAt）为 LWW 依据。

这一节必须写进实现任务，并配单测：两端各在同一会话追加消息 → 合并后顺序按 (timestamp,id)、约束不炸。

---

### 4.6 旧数据 id 不稳定（第二个关键坑）

`business_settings_router.dart:1277-1286` 对**没有 id 的旧数据**合成 id：

```dart
'sha256(sourceKey \u0000 列表下标 \u0000 jsonEncode(payload))' → 'generated_xxxxxxxx…'
```

也就是说同一实体只要在列表里换位或内容微改，id 就会变，同步时表现为「删一条 + 加一条」，两端互相刷。`_restoreSyntheticIdentities`（`business_preferences.dart:195-265`）只是本地往返补丁，**不是**跨设备稳定标识。

实现时的处理（M2 的必做项）：
1. 首次纳入同步时做一次**身份固化迁移**：为每张业务表里 `id` 以 `generated_` 开头的行生成并写回 UUIDv4（写回 payload 里的 id 字段），迁移本身不进同步队列。
2. 固化后把「payload 无 id 就合成」这条路径限制为仅新旧数据导入时使用，并在同步采集器里断言：id 不得以 `generated_` 开头（发现即报错，不静默同步）。
3. 单测：同一实体换位/改内容后 id 不变；两端同一实体的操作收敛为一条记录。

### 4.7 可直接复用的既有能力（决定工作量）

仓库里**没有任何同步脚手架**（`DataSync` 是整包备份引擎、`workspace_session_sync.dart` 只是把附件拷进会话目录、`readTombstones` 目前无人调用、也没有任何 `WHERE updated_at > ?` 的增量查询）。但下列能力可以复用，同步引擎主要写「变更集 + 传输 + 队列 + 冲突裁决」，不必重造：

| 复用 | 位置 | 用途 |
| --- | --- | --- |
| `ChatDatabaseRepository.mergeDatabaseSnapshot` + `_conversationFingerprint` + `_deterministicMergeId` | `chat_database_repository.dart:5290,5617,5843` | 跨设备去重（指纹**刻意排除 `updated_at`**，同内容即等价）、确定性 id 重映射（`merge-<sha256[0:32]>`，冲突再加 `-1/-2`）——**冲突副本直接用它，不要自创** |
| `BusinessSettingsMerger` | `business_settings_merger.dart:48` | 业务实体与偏好的字段级/行级合并、按 `(assistantId, content)` 与 `normalize(content)` 去重、id 重映射。**注意它是「本机优先/补缺」，不看时间戳** → 同步要在它之上加 LWW 判定 |
| `BusinessRestoreService.merge/overwrite`、`BusinessRepository.readSnapshot/transformSnapshot` | `business_restore_service.dart:18,46`、`business_repository.dart:134,177` | 单事务读改写，把远端变更原子地应用进本地库 |
| `BackupScope`（15 分类）+ `BackupContentFilter` | `backup_scope.dart:20`、`backup_content_filter.dart:5` | 同步范围的选择粒度直接复用同一套分类与「键→分类」映射，避免两套语义 |
| `BackupPortability` | `backup_portability.dart:10` | 剥离设备态（linked workspace、`hostPath`、`lastUsedAt`、设备偏好键）——同步必须“不带设备态” |
| `BackupSettingsValidator` | `backup_settings_validator.dart:8` | 远端载荷落地前的守门人 |
| `BackupCancelToken`、`BackupProgress(Sink)`、`runBackupIsolate`、流式 zip 读写 | `backup_cancel_token.dart:16`、`backup_task_progress.dart:22`、`backup_isolate_runner.dart`、`streaming_zip_entry.dart` | 取消/进度/重活隔离，UI 已有渲染管线 |
| `RestoreDurability`、`RestoreWorkspaceLock`、`RestoreBusinessLease`、`RestoreReceipt(Store)` | `restore_durability.dart:7`、`restore_workspace_lock.dart:8`、`restore_business_lease.dart:30`、`restore_receipt.dart:35` | 原子落盘、**与备份/恢复互斥**、崩溃可续的状态机写法（同步自身的 outbox 可照这个模式做） |
| `LocalSnapshotService/Schedule/Store/Retention` + `DatabaseChangeFingerprint` | `local_snapshot_service.dart:62`、`local_snapshot_schedule.dart:36,126` | 准入四道闸（间隔/失败退避/变化指纹/空间）、写-改名发布、保留策略——同步调度与脏检测同构 |
| `S3BackupClient` | `s3_client.dart:14` | 若同步服务另开 S3 兼容存储可直接用；否则其 SigV4 与流式上传可提取 |

**必须新写**（不要试图复用旧管线顶替）：服务端契约与鉴权、设备身份上传（现在 `installationId` 从不出本机）、变更集与 outbox/inbox、增量查询、消息粒度的差量、tombstone 的推送确认位、同步与备份/恢复的全局互斥、远端保留策略、加密模型。

## 5. 同步协议（v1 摘要，完整契约见 `02-api.md`）

| 场景 | 方法 | 说明 |
| --- | --- | --- |
| 配对 | `POST /v1/pair/claim` | 服务器生成一次性配对码（5 分钟），设备扫码/输入换取长期 `deviceToken` |
| 拉取 | `GET /v1/changes?cursor=&limit=` | 返回 `serverSeq > cursor` 的变更，按序 |
| 推送 | `POST /v1/changes` | 批量（≤500 条/次），每条带 `changeId` 保证幂等 |
| 状态 | `GET /v1/state` | 服务端游标、设备列表、配额 |
| 附件 | `POST /v1/blobs` / `GET /v1/blobs/{sha256}` | 内容寻址，上传前查重 |
| 实时（M3） | `GET /v1/stream`（SSE） | 只发「有新变更」通知，客户端再走 pull |

同步循环（每次同步）：

```
pull(cursor) → 应用到本地（事务、幂等） → 更新 cursor
采集本地未推送变更 → push(changeId, records) → 服务端裁决
   → 返回 applied（更新本地记录的服务端版本）与 superseded（本地落败）
   → 落败记录按 §6 处理
```

游标语义：`serverSeq` 单调递增，一台设备的 cursor 只增不减；服务端为每次写入分配 seq，冲突落败的记录也占一个 seq（保证「拉到的和推的结果一致」）。

---

## 6. 冲突策略

统一用「记录级 LWW + 可查的落败副本」，不做 CRDT：

| 数据 | 规则 |
| --- | --- |
| 消息（追加） | 追加即新 id，不存在冲突；两台设备各发各的，全保留 |
| 消息编辑 / 删除 | LWW：`(updatedAt, deviceId)` 字典序大者胜；删除以 tombstone 表达，tombstone 比记录新则记录保持删除 |
| 会话标题 / 置顶 / 模型覆盖 | LWW；落败方保留冲突副本，副本走既有确定性重映射 `_deterministicMergeId`（`merge-<sha256[0:32]>`，撞则加 `-1/-2`），标题追加 `(冲突副本 设备名 日期)`，列表里可见可删 |
| 助手 / 世界书 / 快捷短语等配置 | LWW；落败方保留副本（同上用确定性 id），字段级合并可复用 `BusinessSettingsMerger` 的规则 |
| 记忆条目 | 追加型，天然合并；同 id 修改用 LWW |
| 设置项 | 按 key LWW；设备本地设置不进同步范围 |
| 附件 | 内容寻址，同内容即同对象，无冲突 |

**删除传播**：删除写 tombstone 并同步。现有 tombstone 裁剪期是 90 天（`chat_database_repository.dart:6275-6280`）。服务端应永久保存 tombstone 的 `(scope, entityId, deletedAt)` 三元组（体积很小），客户端本地保留期可维持 90 天；一台设备离线超过保留期再回来，靠服务端的三元组兜底。

**批量重置**：`clearAllData` / 覆盖式恢复**不产生**删除意图（保持现有语义，`app_database.dart:672-674` 已明确）。

---

## 7. 安全与隐私

- **传输**：仅 HTTPS（Caddy 自动签发；无域名则用 IP + 自签，但要接受手机端警告）。服务端只暴露 443。
- **认证**：一次性配对码换长期 deviceToken（每设备独立、可单独撤销）。
- **token 存哪（必须先定）**：仓库现在**没有任何 keystore、没有加密存储**（`pubspec.yaml` 无 flutter_secure_storage；`lib/secrets/` 只有一个没人引用的 `fallback.dart` 占位）。三种落点互斥：
  1. `BusinessPreferences`（SQLite）→ **会随备份导出到 WebDAV/S3 外泄**，不可接受；
  2. SQLite + 登记进 `BackupPortability.devicePreferenceKeys`（`backup_portability.dart:13-20`）→ 留在本地库、不进备份，**推荐**；
  3. `SharedPreferences` + 登记进 `BusinessKeyRegistry.localOnlyKeys`（`business_settings_router.dart:19-33`）→ 最彻底，但这类键会被 `BusinessPreferences` 直接拒绝写入（`business_preferences.dart:274-280`），要换存储通道。
- **API Key 现状**：`provider_rows.payload` 里 `apiKeys`、`oauthCredentials`，以及 `webdav_config_v1`/`s3_config_v1`/代理口令，**当前全是明文存在 `kelivo.db`**。因此同步的默认策略是**不同步密钥字段**（M1/M2），设置页明示「供应商密钥仅本机」。
- **日志脱敏**：新同步客户端必须走既有 `DioHttpClient`（`lib/core/services/network/dio_http_client.dart:78`），它已对请求/响应/错误三处调用 `log_redactor.dart`（敏感 header、`key/token/secret/...` 关键字、`sk-` 等前缀）。自定义 header 命名要能被这些规则命中。
- **端到端加密（M3）**：同步口令经 Argon2id 派生主密钥，敏感 payload 字段 AES-256-GCM；服务端只存密文与版本号，密钥永不上传。注意 `crypto` 包不含 AES-GCM，需要评估既有依赖（`jose` 支持 JWE/A256GCM）或新增一个成熟库——按 AGENTS.md「先查现有依赖」。
- **服务端**：单用户模型；数据库文件与附件卷在 ECS 本地；建议磁盘加密 + 每日快照；同步日志不含正文。

---

## 8. 分期里程碑与验收

### M1 · 端到端最小闭环（先做这个）
范围：对话 + 消息双向同步（含删除传播）、QR 配对、启动时与手动同步、单用户、LWW、服务端 SQLite。
验收（自动化 + 手工双轨）：
1. 两台设备各自离线：A 新建会话发 5 条，B 新建会话发 3 条；网络恢复同步后，两边都看到 2 个会话、8 条消息，顺序与时间戳一致。
2. A 删除一个会话 → 同步后 B 也不再有该会话；B 再改标题不会「复活」它。
3. 重复执行同一批 push（模拟重试）不产生重复消息，`serverSeq` 不倒退。
4. B 删除一条消息 → A 同步后该消息消失，且 A 离线期间的本地新消息保留。
5. 同步中断（杀进程 / 断网）后重来，结果与一次成功同步一致。

### M2 · 其余实体 + 附件 + 后台
范围：助手/世界书/记忆/配置类实体；附件内容寻址上传/懒下载；同步范围设置页；后台自动同步（Android 前台服务或 WorkManager、桌面定时、iOS BGAppRefresh 尽力而为）。
验收：新建助手在两台设备可见；带图片的对话在另一台能看到图片（按需下载）；后台 15 分钟周期内完成自动同步；单会话 1 万条消息的首次同步与增量同步耗时/流量达标（见 §9）。

### M3 · 实时与体验
SSE 变更通知（秒级）、冲突 UI（保留副本 / 采用远端 / 采用本地）、设备管理（查看与撤销）、E2EE、同步诊断页（最近同步、冲突记录、失败原因）。

### M4 · 上游化（可选）
把同步引擎做成可开关的 provider，向 Kelivo 社区提 issue/PR（愿望池 IDEA-0013 已有 157 +1）；在此之前保持为独立分支/补丁集。

### 各平台后台能力（决定 M2 的验收口径）

| 平台 | 能做到 | 做不到 | 实现要点 |
| --- | --- | --- | --- |
| Android | 前台服务（`dataSync` 类型）+ WakeLock；AlarmManager 广播接收器可在 App 未运行时唤醒，并在开机/改时间后重排 | 无限期后台；厂商 ROM 杀进程需用户自行放行 | 直接复用既有 `GenerationForegroundService`（`AndroidManifest.xml:148-153`，`FOREGROUND_SERVICE_DATA_SYNC` 权限已声明 `:21`）与 `.scheduled.ScheduledTaskReceiver`（`:139-147`）。`usesCleartextTraffic="true"`（`:46`）意味着自建内网 http 服务器可用 |
| iOS | 前台任意同步；进入后台后只有 `UIBackgroundTask` 的短暂窗口 | `BGAppRefreshTask`（工程**根本没有** `BGTaskSchedulerPermittedIdentifiers`）、任意时刻后台联网 | 同步定义为「前台 + 下次打开时追赶」；若服务器是明文 http，还需新增 `NSAppTransportSecurity` 例外（当前没有） |
| Windows/macOS/Linux | 进程存活期间（含最小化到托盘）的任意定时同步 | App 退出后的一切调度、开机自启（仓库明确不做 OS 级调度，`desktop_scheduled_tasks.dart:11-13`） | 桌面调度就是 `Timer.periodic` 轮询 + 托盘保活；用户真正退出即停 |

**统一口径**（与仓库既有 `LocalSnapshotSchedule` 的做法一致）：同步的「到点判定」放在**启动 + 回到前台**评估，后台定时只作为尽力而为的补充。UI 上不要承诺「手机后台也在同步」。

---

## 9. 测试计划

- **单元**：变更日志触发器（各表 insert/update/delete）、LWW 比较、tombstone 传播与回收、`messageOrder` 重排、幂等应用（同一批变更应用两次结果相同）、游标推进。
- **集成**：两个内存 Drift 实例 + `httptest` 版同步服务，覆盖：并发改标题、并发追加消息、离线后合并、push 重试、pull 中断续传、附件懒加载。
- **性能**：1 万条消息会话：首次全量同步的耗时与字节数；此后单条新消息的增量同步字节数应 < 2 KB；1000 条变更批量 push 的往返时间。
- **迁移**：从 v1.3.1 现有库升级到带同步表的新 schema；`drift_schemas/` 快照同步更新；旧库无 `updated_at` 的消息用 `timestamp` 兜底。
- **平台**：Android 后台被杀后恢复同步、iOS 后台窗口、桌面托盘定时、Windows 断网重连。
- **门槛**：`dart format lib test`、`dart analyze --fatal-infos lib test`、`flutter test` 全绿；服务端 `go test ./...` + Dart 契约测试（对真实二进制跑一遍协议）。

---

## 10. 部署（摘要，见 `03-deploy.md`）

阿里云 ECS：`/opt/kelivo-sync`，Docker Compose 起 `sync`（Go，仅内网端口）+ `caddy`（443，自动 HTTPS）；数据卷 `./data`（SQLite + 附件）；每日 `sqlite3 .backup` + 附件快照到 OSS 或本地轮转；安全组只开 443（22 限来源 IP）；升级 = 拉新镜像 + `docker compose up -d`，失败回滚上一个 tag。

---

## 11. 风险与对策

| 风险 | 影响 | 对策 |
| --- | --- | --- |
| `messageOrder` / `groupId+version` 唯一约束在合并时冲突，且重排会触发 timeline 触发器 | 同步报错或消息顺序错乱 | 派生字段不参与同步 + 应用后重排 + 重排前丢弃 timeline 索引（§4.5），配专门单测 |
| 旧业务 id 是「下标+内容」哈希 | 换位/改名产生删除+新增，两端互刷 | 首次启用同步时做身份固化迁移（§4.6），采集器拒绝 `generated_` 前缀 |
| 除会话外所有实体的删除都没有墓碑 | 删掉的助手/世界书/消息在多端复活 | 扩展 `tombstone_rows` 的 scope 到所有同步 kind，并在删除路径统一写墓碑（§6） |
| 90 天 tombstone 裁剪 | 长期离线设备复活已删数据 | 服务端永久保留 tombstone 三元组 |
| 备份恢复与同步叠加 | 覆盖式恢复把同步状态一起换掉，产生「幽灵变更」 | 恢复后重建同步基线（cursor 归零 + 全量快照比对）；同步元数据表与备份的取舍要在实现时明确定义 |
| 附件 `asset_rows.path` 是设备本地路径 | 直接同步会让另一台设备指向不存在的文件 | payload 不同步 `path`/`thumbnail_path`；按 `content_hash` 在本地解析出真实路径（`kelivo-file:///` 约定见 `kelivo_file_uri.dart:5-23`） |
| 同步引擎自己开第二个数据库连接 | WAL 下与前台写并发、订阅失效、事务互相阻塞 | 复用现有 `ChatDatabaseGateway` / `AppDatabase` 单例，所有写入走同一连接（`chat_database_gateway.dart:87-108`） |
| 影子索引（timeline / FTS）被写脏 | 搜索召回已删内容、时间线错乱 | 合并后按仓库既有能力 DROP 重建（`message_timeline_index.dart:22-35`、`chat_database_repository.dart:4105-4125`） |
| 同步与备份/恢复争用数据库与资产目录 | 半写、恢复失败、数据错乱 | 同步必须进入既有的 `RestoreWorkspaceLock` / `RestoreBusinessLease`；与备份、恢复、本地快照全局互斥（§4.7） |
| 覆盖式恢复（含对话）不当场生效 | 同步后立刻读回会读到旧数据 | 恢复写的是候选 bundle，真正切换在**下次冷启动**由 CutoverExecutor 完成；同步基线要在重启后再校准一次 |
| 恢复成功后进程被写栅栏锁死到重启 | 同步 worker 被一并挡住 | 重启后再启动同步；UI 上也要避免显示「同步中」 |
| 远端目录污染 | 若把同步对象和备份包放同一目录，WebDAV 列表不筛扩展名（S3 只留 `.zip`）会互相干扰 | 同步服务用自己的 endpoint/路径前缀，不复用备份目录 |
| 合并管线不合并墓碑，且指纹刻意排除 `updated_at` | 删除不会随旧合并路径传播；编辑后又改回原样会被判为“无变化” | 删除传播走专用的 tombstone 通道；内容判等接受该语义（幂等优先） |
| 服务端 SQLite 单写者 | 并发写冲突 | WAL + 串行写队列（单进程足够；上量再换 Postgres） |
| iOS 后台限制 | 后台同步不可靠 | 前台同步为主，BGTask/通知为辅；文档明确「打开即同步」的预期 |
| E2EE 与搜索/统计冲突 | 服务端无法检索正文 | 明确取舍：加密后检索只在本机做 |
| 上游合并冲突（fork 分叉） | 维护成本 | 分层设计：同步引擎独立目录、尽量不改现有文件；M4 再谈上游 |

---

## 12. 需要你（用户）确认的决策点

1. **服务端语言**：Go（推荐：单二进制、ECS 最小规格友好）还是 TypeScript。
2. **API Key 是否同步**：建议默认不同步，M3 用 E2EE 后再放开（你的选择会影响设置页文案）。
3. **实时性**：要不要 SSE 秒级（M3），还是「打开 App / 手动点一下」就够（M1）。
4. **路线**：自己 fork 用，还是准备提回 Kelivo 上游（影响代码组织与是否加开关）。
5. **域名与证书**：有没有域名？（没有的话手机端要接受自签证书，体验会差一点）
6. **服务器规格**：ECS 内存/磁盘多少，是否已有 Docker（影响是否加 Postgres、附件放本地还是 OSS）。
