# 实施任务清单（给 Codex）

仓库：`D:\projects\bot-workspace\kelivo`（v1.3.1+80）。方案依据：`01-plan.md`、`02-api.md`。
**每个 PR 独立提交，先做 PR1→PR2（纯本地、可测），再做 PR7（服务端），最后接线 PR3→PR6。**

## 全局门槛（每个 PR 必须过）

```bash
dart format lib test integration_test
dart analyze --fatal-infos lib test integration_test
flutter test
```
CI 同样跑这几条（`.github/workflows/pr-check.yml:31-85`），另外会跑 `flutter gen-l10n` 校验 ARB 生成物一致。

Drift 相关代码生成与快照（命令出处 `lib/core/database/schema_migrations.dart:37-39`）：
```bash
dart run build_runner build
dart run drift_dev schema dump lib/core/database/app_database.dart drift_schemas/app_database/
dart run drift_dev schema generate drift_schemas/app_database/ test/core/database/generated_schema/
dart run drift_dev schema steps drift_schemas/app_database/ lib/core/database/schema_versions.dart
```

---

## PR1 · schema v4：变更日志、同步状态、墓碑扩展

**依赖**：无。

**新增文件**
- `lib/core/services/sync/sync_kind.dart` — 同步实体枚举（`conversation`/`message`/`tombstone`/…）与表映射。
- `test/core/database/sync_change_log_test.dart` — 触发器单测。

**修改文件**
- `lib/core/database/app_database.dart`
  - 新增 `SyncChangeLogRows`（见 `01-plan.md` §4.4）与 `SyncStateRows`（键值：cursor、deviceId、serverUrl）。
  - `currentSchemaVersion` 3 → 4；`publishedSchemaVersions` 加 4；`onUpgrade` 加 `from3To4`：建两张表 + 索引 + 触发器（**索引/触发器必须显式 `m.create`/`customStatement`**，参考 `:930-943` 的注释）。
  - 触发器只挂在 M1 相关表上：`conversation_rows`、`message_rows`、`message_part_rows`、`message_prompt_rows`、`message_asset_rows`、`tombstone_rows`。`message_rows` 的时间戳取 `COALESCE(new.updated_at, new.timestamp)`。
- `lib/core/database/chat_database_repository.dart`
  - 权威列顺序清单 `currentSchemaColumns`（`:862-1007`）与必需表集合（`:803-833`）按新 schema 更新；新表加进必需表。
  - `deleteMessage` / 消息删除路径补写墓碑（现在只有 `deleteConversation` 写，`:6257-6283`）。
- 生成物：`app_database.g.dart`、`lib/core/database/schema_versions.dart`、`drift_schemas/app_database/drift_schema_v4.json`、`test/core/database/generated_schema/**`。

**验收**
- 新库建库后 `sync_change_log` 存在且触发器生效：插入/更新/删除会话与消息各产生一条日志（`op`、`updated_at` 正确）。
- 消息的 `updated_at` 为 NULL 时日志写入 `timestamp`（老库升级场景）。
- 迁移：用 `drift_schemas` 的 v3 快照建库 → 升级到 v4 → 无报错，`app_database_schema_test.dart` 通过。
- `flutter test test/core/database/` 全绿。

**不要做**：不要给现有表加列（除必要的新表）；不要动 `timeline_*` / `message_search_fts` 的定义。

---

## PR2 · 同步核心（纯逻辑，不碰网络）

**依赖**：PR1。

**新增文件**
- `lib/core/services/sync/sync_record.dart` — wire record（kind/id/updatedAt/deleted/originDevice/payload）与 JSON 编解码。
- `lib/core/services/sync/lww.dart` — `(updatedAt, deviceId)` 比较器。
- `lib/core/services/sync/change_collector.dart` — 从 `sync_change_log` 读未推送变更，按 `(kind,id)` 折叠为最新一条。
- `lib/core/services/sync/remote_applier.dart` — 把远端变更写入 Drift：单事务、幂等、按 kind 分派。
- `test/core/services/sync/{lww,colleactor,applier}_test.dart`（内存库：`NativeDatabase.memory()`）。

**关键实现要点**
1. **幂等**：同一批变更应用两次结果相同；已应用过的 `(kind,id,updatedAt)` 直接跳过。
2. **消息重排**：应用远端消息后按 `(timestamp, id)` 重排该会话的 `message_order`；重排前丢弃该会话的 timeline 索引，重排后再按其既有机制重建（`message_timeline_index.dart:22-35`）。必须满足 `conversation_message_order` 的严格递增校验（`chat_database_repository.dart:5815-5824`）。
3. **流式跳过**：`is_streaming=1` 的消息不进同步队列，也不被远端覆盖。
4. **外键顺序**：先 `conversation` 再 `message` 再 `message_part`；删除按逆序，或依赖 `ON DELETE CASCADE` + 墓碑。
5. **冲突落败**：`superseded` 记录按 `01-plan.md` §6 处理（会话/助手保留冲突副本；消息直接采用服务端版本）。
6. **不做 IO**：这一层只依赖 `AppDatabase`，方便单测。

**复用既有能力（别重造）**
- 跨设备去重与冲突重映射：`ChatDatabaseRepository.mergeDatabaseSnapshot`（`chat_database_repository.dart:5290`）、`_conversationFingerprint`（`:5617`，刻意排除 `updated_at`）、`_deterministicMergeId`（`:5843`）。**冲突副本必须用这套确定性 id**，不要自创命名规则。
- 业务实体的原子应用：`BusinessRestoreService.merge`（`business_restore_service.dart:46`）/ `BusinessRepository.transformSnapshot`（`business_repository.dart:177`）。
- 远端载荷落地前的校验：`BackupSettingsValidator`（`backup_settings_validator.dart:8`）。
- 进度与取消：`BackupProgressSink`（`backup_task_progress.dart:22`）、`BackupCancelToken`（`backup_cancel_token.dart:16`）。

**验收**
- 两个内存库 A/B，互相应用对方变更后：会话集合、消息顺序、删除状态一致。
- 同一变更应用两次不产生重复消息，`message_order` 不出现空洞错乱。
- 两端在同一会话各追加 3 条消息 → 合并后 6 条，顺序按 (timestamp,id)，无唯一约束异常。
- `flutter test test/core/services/sync/` 全绿。

---

## PR7 · 服务端 `kelivo-sync`（Go + SQLite）

**依赖**：无（可与 PR1/PR2 并行）。**先做后端，PR3 才能联调。**

**新增文件**（新目录，建议 `kelivo-sync/`，与 App 分仓或同仓子目录由你决定）
- `cmd/kelivo-sync/main.go`、`internal/api/{routes,handlers,auth}.go`、`internal/store/{sqlite,records,changes,devices,blobs}.go`、`internal/config/config.go`
- `Dockerfile`、`docker-compose.yml`、`Caddyfile`、`README.md`（按 `03-deploy.md`）
- `internal/api/*_test.go`（httptest）

**实现要求**：完全按 `02-api.md`（表结构、限额、错误码、幂等、`serverSeq` 语义）。要点：
1. `pair-code` 子命令生成一次性配对码；`claim` 换 token（token 只存哈希）。
2. push 幂等：`changeId` 命中 `push_receipts` 直接回放首次响应。
3. 裁决：`(updatedAt, deviceId)` LWW；落败写入 `superseded` 且同样占用 `serverSeq`。
4. `GET /v1/changes` 单调、可续传；`GET /v1/snapshot` 提供首次基线。
5. 附件：`blobs` 目录 + sha256 校验 + 引用计数。
6. 启动时自动迁移 schema（只追加）；迁移前自动备份 `sync.db`。
7. 日志只记元数据，绝不记 payload 正文。

**验收**
- `go test ./...` 全绿；含：并发 push 同一记录、重复 changeId、cursor 边界、超大 payload 拒绝、token 撤销后 401。
- 用 `docker compose up` 起服务，按 `03-deploy.md` 完成一次配对码→claim→pull/push 的 curl 冒烟。

---

## PR3 · 客户端传输层

**依赖**：PR1（读写同步状态）、PR7（可联调）。

**新增文件**
- `lib/core/services/sync/sync_api_client.dart` — `dio` 实现 `02-api.md` 全部接口；统一超时、指数退避、`Retry-After`、401 上报「需重新配对」。
- `lib/core/services/sync/sync_settings.dart` + `lib/core/providers/sync_settings_provider.dart` — 服务器地址、开关、上次同步时间、设备名。
- `test/core/services/sync/sync_api_client_test.dart` — 用 `DioAdapter`/本地 httptest 服务端做契约测试（同一个测试对 Go 实现运行）。

**修改文件**
- 令牌与游标存储：见下方「token 存哪」决策；游标/状态放 `sync_state_rows` 或复用 `JsonBlobStore`（`lib/core/services/json_blob_store.dart:11`，自带 `runExclusive` 串行队列）。

**硬约束**
- **HTTP 必须走 `DioHttpClient`**（`lib/core/services/network/dio_http_client.dart:78`）：它已统一超时、代理（含 SOCKS5）、取消与**日志脱敏**（`log_redactor.dart`）。不要自己 new `http.Client()`，否则 token 可能进日志。
- **token 存哪（先定，三选一，互斥）**：① `BusinessPreferences` → 会随 WebDAV/S3 备份外泄，**禁止**；② SQLite + 加入 `BackupPortability.devicePreferenceKeys`（`backup_portability.dart:13-20`）→ **推荐**；③ `SharedPreferences` + 加入 `BusinessKeyRegistry.localOnlyKeys`（`business_settings_router.dart:19-33`）→ 最彻底，但该键会被 `BusinessPreferences.setString` 拒绝（`business_preferences.dart:274-280`），必须改走 SharedPreferences。
- WebDAV/S3 的传输实现是 `DataSync` 的**私有方法**，且语义是「用户自己的存储」，**不能当同步服务客户端复用**。

**验收**
- 契约测试覆盖每个 endpoint 的成功与错误路径。
- 断网 → 退避重试 → 恢复后成功；token 失效时给出明确状态。
- 抓包/日志检查：请求头里的 token 不出现在任何日志中（`log_redactor` 生效）。

---

## PR4 · 同步引擎与 Provider

**依赖**：PR2、PR3。

**新增文件**
- `lib/core/services/sync/sync_engine.dart` — 单向互斥的 `sync()`：先 pull 应用、再 push 本地待推、最后把 `applied` 的 `serverSeq` 并入 cursor；对外暴露 `Stream<SyncStatus>`。
- `lib/core/providers/sync_provider.dart` — 状态与进度（idle/syncing/error/conflicts）、手动触发。

**修改文件**
- `lib/core/database/chat_database_gateway.dart` — 让同步引擎拿到**同一个** `AppDatabase`/仓储实例（禁止另开连接；WAL 下第二连接会与前台写互相阻塞）。
- 应用启动处（`lib/main.dart`）注册 provider 与首次同步触发。

**验收**
- 集成测试：两个客户端（两个临时目录的库）+ 真实 Go 服务端二进制，跑通「离线各写 → 同步 → 一致」。
- 同步过程中杀进程 → 重启后同步结果与一次成功同步一致（幂等）。
- 同一时刻只允许一个同步在跑（重复点击不发双请求）。

---

## PR5 · 设置页与配对 UI

**依赖**：PR4。

**新增文件**
- `lib/features/settings/pages/sync_settings_page.dart`（移动布局）
- `lib/desktop/setting/sync_pane.dart`（桌面布局，参考同目录 `backup_pane.dart`）
- 配对页：服务器二维码展示（`pretty_qr_code`）+ 手机扫码（`mobile_scanner`，参考 `lib/features/scan/`）
- 冲突列表组件（保留副本 / 采用远端 / 采用本地）

**修改文件**
- `lib/features/settings/pages/settings_page.dart`、`lib/features/settings/pages/more_page.dart`、`lib/desktop/setting/settings_pane*.dart` — 挂入口
- `lib/l10n/app_en.arb`、`app_zh.arb`、`app_zh_Hant.arb` + 跑 `flutter gen-l10n`
- UI 组件一律用 `lib/shared/widgets/`、`lib/shared/dialogs/` 里已有的（`SectionCard`、`CustomBottomSheet`…），桌面端**不要**用 bottom sheet（仓库约定）

**验收**
- 移动/桌面两种布局各验证一遍；配对码过期、服务器不可达、token 失效三种状态都有明确提示。
- `flutter analyze --fatal-infos` 通过；三语文案齐全。

---

## PR6 · 后台触发

**依赖**：PR4。

**新增/修改文件**
- `lib/core/services/sync/sync_scheduler.dart` — 触发策略：应用启动、App 回前台、本地写入后 30 秒去抖、周期兜底；调度语义照抄 `LocalSnapshotSchedule`（`lib/core/services/backup/local_snapshot_schedule.dart:126-184`）的准入闸门与失败退避。
- Android：复用既有 `GenerationForegroundService`（`AndroidManifest.xml:148-153`，`foregroundServiceType="dataSync"`，权限 `:21` 已声明）；若要「App 未运行也能同步」，复用 `.scheduled.ScheduledTaskReceiver` 的 alarm + boot/time 重排（`:139-147`）。
- 桌面：`Timer.periodic` + 托盘保活（参考 `lib/core/services/desktop_scheduled_tasks.dart:88-166`）；**不要**期待开机自启（仓库明确不做 OS 级调度，`:11-13`）。
- iOS：**当前工程没有 `BGTaskSchedulerPermittedIdentifiers`、没有 `NSAppTransportSecurity`**。结论：后台同步只做「前台 + 下次打开追赶」；如果要连明文 `http://` 的自建服务器，必须新增 ATS 例外；若要与系统后台刷新结合，需另加 Info.plist 声明与 `BGAppRefreshTask`（属于额外范围，先不做）。

**互斥要求**
- 同步必须与**备份、恢复、本地快照**互斥：进入既有的 `RestoreWorkspaceLock`（`restore_workspace_lock.dart:8`）/ `RestoreBusinessLease`（`restore_business_lease.dart:30`）并调用快照的 busy 检查，禁止并发写。

**验收**
- 桌面进程存活（含最小化到托盘）时 15 分钟周期能自动同步；Android 切后台期间完成一次同步；iOS 明确「打开即同步」。
- 一次同步未结束时被再次触发不会并发（有锁 + 去抖）。
- App 退出、进程被杀后重开：能追赶上次未完成的同步。

---

## PR8（M2）· 其余实体与附件通道

- 同步范围扩展到：`assistant`、`worldbook`、`memory`（`assistant_memory_rows` + `memory_entry_rows` + `user_profile_field_rows`）、`quickPhrase`、`searchService`、`ttsService`、`mcpServer`、`instructionInjection`、`assistantTag`、`providerGroup`、`workspace`/`skill`（`extension_entity_rows`）。
- **先做 id 固化迁移**（`01-plan.md` §4.6）：把 `generated_` 前缀的业务行改写成 UUIDv4。
- 附件：按 `content_hash` 走 `/v1/blobs`（内容寻址、懒下载）；同步时**不传** `asset_rows.path` / `thumbnail_path`，落地后按本地目录重写；消息里 `kelivo-file:///` 引用的解析见 `kelivo_file_uri.dart:5-23`。
- 供应商：默认只同步非密钥字段（`provider_rows.payload` 里的 `apiKeys`、`oauthCredentials` 等排除）。注意这些密钥**现在本来就是明文存在 `kelivo.db` 里的**，同步要保证它们不出本机。

**复用既有能力（这一期几乎全靠复用）**
- 范围语义与「键→分类」映射：`BackupScope`（`lib/core/models/backup_scope.dart:20`）+ `BackupContentFilter`（`lib/core/database/backup_content_filter.dart:5`）——同步的分类必须与备份完全一致，不要另立一套。
- 业务序列化：`BusinessSettingsRouter.exportSnapshot/exportSnapshotWithRowIds`（`business_settings_router.dart:281,307`）+ `BusinessSnapshot/BusinessEntityKind`（`business_data.dart:8,61`）。
- 合并与冲突：`BusinessSettingsMerger`（`business_settings_merger.dart:48`，字段级/按 id/去重/重映射；**不看时间戳**，LWW 要自己加）+ `BusinessRestoreService.merge`（`business_restore_service.dart:46`）。
- 设备态剥离：`BackupPortability.portable/preserveDeviceState`（`backup_portability.dart:25,62`）——工作区 `hostPath`、linked workspace、`defaultWorkspaceId` 一律不传。
- 附件现状提醒：现在只有「整根打包 + 只补不存在」（`data_sync.dart:2507-2537`），**没有任何按文件差量/删除传播**，这部分是新增工作。

**验收**：助手/世界书/记忆在两端一致；删除能传播；带图片的对话在另一端能看到图（按需下载）；密钥不离开本机（抓包验证）。

---

## PR9（M3）· 实时、冲突 UI、E2EE

- SSE 通道（`/v1/stream`）→ 触发一次 pull。
- 冲突 UI：把 `superseded` 的处理结果展示给用户。
- E2EE：口令 → Argon2id 派生主密钥 → 敏感字段 AES-256-GCM；服务端只存密文与密钥版本；提供恢复码；明确「服务端不再可检索正文」的取舍。
- 设备管理页：查看/撤销设备。

---

## 交付顺序速查

```
PR1 ─→ PR2 ─┐
            ├─→ PR4 ─→ PR5
PR7 ─→ PR3 ─┘        └─→ PR6
PR8 / PR9 视 M2/M3 排期
```
