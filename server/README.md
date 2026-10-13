# Kelivo Sync（M1）

单用户、自托管对话与消息同步。每个配对设备均能查看全部同步数据并撤销设备。
正文在服务器 SQLite 中以明文存储；当前没有附件二进制通道或端到端加密。

## WSL

```sh
go test -race ./...
go build -o kelivo-sync .
./kelivo-sync -db data/sync.db
# 第二个终端：生成一个 5 分钟有效、一次性的配对码
./kelivo-sync -db data/sync.db pair-code
```

默认仅监听 `127.0.0.1:8787`。Android 真机联调需 HTTPS 反代；HTTP 仅允许明确启用的本地开发模式，不用于公网。

## HTTPS 部署

在 `.env` 中填写 `SYNC_DOMAIN=sync.example.com`，域名解析指向服务器，然后运行：

```sh
docker compose up -d --build
docker compose exec sync /kelivo-sync -db /data/sync.db pair-code
```

若构建机无法连接 `proxy.golang.org`，先运行
`docker compose build --build-arg GOPROXY=https://goproxy.cn`，再启动服务。

数据存在 Docker volume `sync_data`。备份使用 SQLite `.backup` 或停服务后备份卷，不能单独复制正在写入的 `sync.db`。

## 协议相对交接草案的修正

- M1 只接受 `conversation`/`message`。删除直接为同 kind 的 `deleted: true` 记录，永久保留；不另发重复 tombstone wire record。
- push 回执 `superseded[].winner` 含完整胜出记录。客户端不能以 push 回执推进 pull 游标。
- 同版本/同正文为 no-op。落败请求不分配空的 sequence；仅实际胜出变化进入 changes。
- 幂等键按 `(deviceId, changeId)` 隔离，并拒绝相同键不同内容。
- pull 不过滤 kind（M1 全范围同步）。首次同步从 cursor=0 分页拉取，沿用同一崩溃恢复逻辑。
- 会话删除不允许旧 ID 复活；恢复需新建 ID。配对码只存 SHA-256 哈希，token 亦只存哈希。
- 单 payload 最大 1 MiB，单批最大 500 条，整个请求最大 16 MiB。

数据库 schema 版本为 1，当前无历史版本迁移。后续变更须先使用 SQLite 一致快照备份，再执行事务迁移；当前程序拒绝更高版本库。
