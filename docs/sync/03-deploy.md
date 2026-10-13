# Kelivo Sync 服务端 · 部署与运维（阿里云 ECS）

目标：一台 ECS 上跑起同步服务，手机/电脑通过 HTTPS 访问；数据在本地卷，每日快照；升级可回滚。

## 1. 目录与组件

```
/opt/kelivo-sync/
├── docker-compose.yml
├── Caddyfile
├── .env                  # 域名、镜像 tag、管理员口令
└── data/                 # 卷：sync.db（SQLite WAL）、blobs/
```

- `sync`：kelivo-sync 单二进制镜像，监听容器内 `8080`，不对外暴露。
- `caddy`：反向代理 + 自动 HTTPS（Let's Encrypt），只对外开 443。
- 资源建议：2 核 / 2 GB 起（SQLite + 附件；附件多或多人用再考虑 OSS 与 Postgres）。

## 2. docker-compose.yml

```yaml
services:
  sync:
    image: ghcr.io/<you>/kelivo-sync:${TAG:-0.1.0}
    restart: unless-stopped
    environment:
      KELIVO_SYNC_ADDR: ":8080"
      KELIVO_SYNC_DB: /data/sync.db
      KELIVO_SYNC_BLOBS: /data/blobs
      KELIVO_SYNC_MAX_BLOB_MB: "50"
      KELIVO_SYNC_RATE_PER_MIN: "600"
    volumes:
      - ./data:/data
    healthcheck:
      test: ["CMD", "/kelivo-sync", "health"]
      interval: 30s
      timeout: 5s
      retries: 3

  caddy:
    image: caddy:2
    restart: unless-stopped
    ports: ["443:443", "80:80"]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
    depends_on: [sync]

volumes:
  caddy_data:
```

## 3. Caddyfile

```caddy
sync.example.com {
    encode zstd gzip
    request_body {
        max_size 60MB
    }
    reverse_proxy sync:8080
}
```

无域名时（不推荐，手机需信任自签证书）：
```caddy
:443 {
    tls internal
    reverse_proxy sync:8080
}
```

## 4. 首次部署

```bash
# 1. 安全组：只开 443（80 供 ACME 校验，可留）；22 限制来源 IP
# 2. 装 Docker（阿里云 ECS 可用镜像加速）
curl -fsSL https://get.docker.com | sh
# 3. 项目文件
mkdir -p /opt/kelivo-sync && cd /opt/kelivo-sync
# 写入 docker-compose.yml / Caddyfile / .env
docker compose up -d
# 4. 生成第一个配对码（5 分钟有效，一次性）
docker compose exec sync /kelivo-sync pair-code
# 5. 手机/电脑 Kelivo → 设置 → 多设备同步 → 扫配对二维码或输入配对码
```

## 5. 备份与恢复

- **数据库**：每天 `sqlite3 data/sync.db ".backup '/backup/sync-$(date +%F).db'"`（不要直接拷 WAL 状态下的文件）。
- **附件**：`data/blobs/` 内容寻址、只增不减，用 `rsync -a --link-dest` 做增量快照即可。
- **异地**：把每日快照推到阿里云 OSS（`ossutil cp -r`），保留 30 天。
- **恢复**：停容器 → 放回 `sync.db` 与 `blobs/` → 起容器。客户端不需要改任何东西（cursor 仍然有效；若服务端 seq 回退，客户端会收到 `cursor_ahead`，按提示重建基线）。

`backup.sh` 参考：
```bash
#!/usr/bin/env bash
set -euo pipefail
cd /opt/kelivo-sync
mkdir -p backup
sqlite3 data/sync.db ".backup 'backup/sync-$(date +%F).db'"
ossutil cp -f "backup/sync-$(date +%F).db" oss://<bucket>/kelivo-sync/
find backup -name 'sync-*.db' -mtime +30 -delete
```
加 crontab：`15 3 * * * /opt/kelivo-sync/backup.sh >> /var/log/kelivo-sync-backup.log 2>&1`

## 6. 升级与回滚

```bash
cd /opt/kelivo-sync
sed -i 's/^TAG=.*/TAG=0.2.0/' .env
docker compose pull && docker compose up -d
docker compose logs -f sync          # 观察启动与迁移日志
# 回滚
sed -i 's/^TAG=.*/TAG=0.1.0/' .env && docker compose up -d
```
服务端 schema 迁移必须**只追加**（新表/新列），且启动时先做一次自动备份，迁移失败时拒绝启动。

## 7. 运维检查表

- [ ] 安全组只开 443（+ ACME），22 限 IP，关闭其他端口
- [ ] `sync.db` 与 `blobs/` 在独立卷，磁盘使用率告警（>80%）
- [ ] 每日快照 + 每周抽查一次恢复
- [ ] 日志只记元数据（时间、设备、条数、冲突数），不记正文
- [ ] 设备列表定期核对，废弃设备立即撤销
- [ ] 服务端版本与客户端最低版本约定（`GET /v1/state` 返回 `minClientVersion`）
- [ ] 限流与单文件上限按实际使用调整

## 8. 隐私与合规

- 服务端只保存用户自己的聊天记录与附件；不接第三方分析/日志服务。
- 未启用 E2EE 时，服务端磁盘上可读正文 → 磁盘加密 + 严格 SSH 是本方案的安全边界，文档要向用户讲清。
- 启用 E2EE（M3）后，服务端只存密文；代价是服务端侧检索不可用。
