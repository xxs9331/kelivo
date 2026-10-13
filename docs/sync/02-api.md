# Kelivo Sync API v1 · 接口契约

服务端：`kelivo-sync`（Go + SQLite）。所有请求/响应 `application/json; charset=utf-8`，除附件外全部走 HTTPS。
时间统一为**微秒级 Unix 时间戳（UTC，整数）**。`serverSeq` 为服务端单调递增整数。

## 1. 认证

- 配对阶段：`X-Pair-Code: <一次性码>`（5 分钟有效，成功后立即作废）
- 之后所有请求：`Authorization: Bearer <deviceToken>`
- 设备信息通过请求头透传：`X-Device-Id: <installationId>`、`X-Device-Name: <人类可读名>`

错误格式统一：

```json
{ "error": { "code": "invalid_token", "message": "device token revoked" } }
```

| code | HTTP | 含义 |
| --- | --- | --- |
| `invalid_pair_code` | 401 | 配对码错误/过期/已用 |
| `invalid_token` | 401 | token 无效或已撤销 |
| `payload_too_large` | 413 | 单条或单批超出上限 |
| `cursor_ahead` | 409 | 客户端 cursor 大于服务端（数据库被回滚过，需重新基线） |
| `rate_limited` | 429 | 触发限流，带 `Retry-After` |
| `server_error` | 500 | 服务端故障，可重试 |

## 2. 配对

### `POST /v1/pair/claim`
```json
// 请求
{ "code": "7F3K-9Q2M", "deviceId": "uuid", "deviceName": "Pixel 8", "platform": "android" }
// 响应
{ "deviceToken": "…", "serverId": "kelivo-sync-01", "serverTimeUs": 1791859673443000 }
```
配对码由部署时生成（`docker compose exec sync ./kelivo-sync pair-code`），一次性。

### `GET /v1/devices` / `DELETE /v1/devices/{deviceId}`
列出/撤销设备（撤销后该设备 token 立即失效）。

## 3. 变更拉取

### `GET /v1/changes?cursor=<seq>&limit=<n>&kinds=conversation,message`
```json
{
  "changes": [
    {
      "serverSeq": 1042,
      "kind": "message",
      "id": "uuid",
      "updatedAt": 1791859673443000,
      "deleted": false,
      "originDevice": "uuid",
      "payload": { "…": "…" }
    }
  ],
  "nextCursor": 1042,
  "hasMore": true,
  "serverTimeUs": 1791859673443000
}
```
规则：
- 只返回 `serverSeq > cursor`，按 `serverSeq` 升序；`limit` 默认 500、上限 2000。
- `payload` 在该 kind 被 `kinds` 过滤时不返回，但 `serverSeq` 仍推进（避免重复扫描）。
- 删除记录：`deleted: true`，`payload` 为 `null`；tombstone 以 `kind: "tombstone"` 记录返回（`payload: {"scope":"conversation","entityId":"…","deletedAt":…}`）。
- 服务端不裁剪 tombstone 记录（体积小），客户端可自行忽略本地已处理的。

## 4. 变更推送

### `POST /v1/changes`
```json
{
  "changeId": "uuid-per-batch",          // 幂等键：同 changeId 重放返回首次结果
  "deviceId": "uuid",
  "records": [
    {
      "kind": "message",
      "id": "uuid",
      "updatedAt": 1791859673443000,
      "deleted": false,
      "payload": { "…": "…" }
    }
  ]
}
```
```json
{
  "applied":   [ { "kind": "message", "id": "uuid", "serverSeq": 1043, "serverUpdatedAt": 1791859673500000, "status": "applied" } ],
  "superseded":[ { "kind": "conversation", "id": "uuid", "serverSeq": 1044, "serverUpdatedAt": 1791859673550000, "status": "superseded", "winnerDevice": "uuid", "winnerUpdatedAt": 1791859673540000 } ],
  "nextCursor": 1044,
  "serverTimeUs": 1791859673550000
}
```
规则：
- 单批 ≤ 500 条、单条 payload ≤ 1 MB（超出返回 `payload_too_large`）。
- **幂等**：`changeId` 已处理过 → 直接返回首次结果，不再写入。
- **裁决**：对同一 `(kind,id)`，比较 `(updatedAt, deviceId)` 字典序；大者胜并写入新 `serverSeq`；落败者列入 `superseded`（也占一个 seq，保证其它设备能看到裁决结果）。
- 首见记录直接写入。
- 客户端处理后必须把 `applied` 的 `serverSeq` 合入自己的 cursor（避免下次 pull 重复拿到自己的写入）。

## 5. 全量基线（首次 / 数据被重置）

### `GET /v1/snapshot?kinds=conversation,message`
流式返回当前所有记录的**最新版本**（NDJSON，一行一条，与 §3 的 change 结构一致），首行是 `{"kind":"_meta","cursor":1234}`。用于新设备首次同步，避免逐条 pull。客户端处理完后 cursor 设为该值。

### `GET /v1/state`
```json
{ "cursor": 1044, "deviceCount": 2, "recordCounts": { "conversation": 42, "message": 981 }, "attachmentBytes": 12345678, "serverTimeUs": 1791859673550000 }
```

## 6. 附件（内容寻址）

| 接口 | 说明 |
| --- | --- |
| `POST /v1/blobs/check` | 请求 `{"sha256":[…],"sizes":[…]}` → 返回服务端**缺失**的哈希，用于批量预检 |
| `PUT /v1/blobs/{sha256}` | 上传二进制（`application/octet-stream`，≤ 50 MB/个）；已存在返回 `200` 且不覆盖 |
| `GET /v1/blobs/{sha256}` | 下载，带 `ETag`/`Cache-Control: immutable`；支持 `Range` |
| `DELETE /v1/blobs/{sha256}` | 仅在该对象无人引用时允许（服务端按 `asset` 记录引用计数） |

## 7. 实时通知（M3）

### `GET /v1/stream`（SSE）
```
event: changed
data: {"serverSeq": 1045, "kinds": ["message"]}
```
仅用于「有新变更」的提示，正文仍走 `GET /v1/changes`。客户端断线后退避重连，重连成功后照常 pull。

## 8. 同步循环（客户端实现规范）

```
1. 若 cursor 为空 → GET /v1/snapshot 建基线，落 cursor
2. 否则循环：pull(cursor) → 应用（单事务、幂等）→ cursor = nextCursor，直到 hasMore=false
3. 采集 sync_change_log 中 pushed=0 的记录（按 local_seq 升序、按 kind 分批）
4. push(batch) → 对 applied 记录标记 pushed、记录 pushed_seq；
   对 superseded 记录按冲突策略处理（§6 of 01-plan.md）
5. 把 applied/superseded 的 serverSeq 合入 cursor
6. 失败重试：指数退避（1s→2s→…→5min），网络恢复、应用回到前台、手动点击时立即重试
```

## 9. 服务端表结构（SQLite）

```sql
CREATE TABLE devices (
  device_id TEXT PRIMARY KEY, name TEXT, platform TEXT,
  token_hash TEXT NOT NULL, created_at INTEGER NOT NULL, revoked_at INTEGER
);
CREATE TABLE records (            -- 每个 (kind,id) 一行，保存当前胜出版本
  kind TEXT NOT NULL, id TEXT NOT NULL,
  updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
  origin_device TEXT NOT NULL, payload TEXT,
  server_seq INTEGER NOT NULL,
  PRIMARY KEY (kind, id)
);
CREATE INDEX idx_records_seq ON records(server_seq);
CREATE TABLE changes (            -- 变更序列（append-only，供增量拉取）
  server_seq INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL, id TEXT NOT NULL,
  updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
  origin_device TEXT NOT NULL, payload TEXT
);
CREATE TABLE tombstones (         -- 永久保留的删除意图
  scope TEXT NOT NULL, entity_id TEXT NOT NULL, deleted_at INTEGER NOT NULL,
  server_seq INTEGER NOT NULL, PRIMARY KEY (scope, entity_id)
);
CREATE TABLE push_receipts (      -- 幂等
  change_id TEXT PRIMARY KEY, response TEXT NOT NULL, created_at INTEGER NOT NULL
);
CREATE TABLE blobs (
  sha256 TEXT PRIMARY KEY, size INTEGER NOT NULL, ref_count INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);  -- pair_code 等
```
保留策略：`changes` 可定期压缩——对每个 `(kind,id)` 只保留最近一次 seq，其余行折叠为「快照行」，但不能删掉比最慢设备 cursor 更新的行。`push_receipts` 保留 30 天。

## 10. 限额与默认值

| 项 | 默认 |
| --- | --- |
| 单批变更 | 500 条 |
| 单条 payload | 1 MB |
| 单个附件 | 50 MB |
| 拉取 limit | 500（上限 2000） |
| token 有效期 | 长期（可撤销） |
| 配对码有效期 | 5 分钟，一次性 |
| 限流 | 每设备 600 请求/分钟 |
