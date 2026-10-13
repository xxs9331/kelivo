# 多设备同步实施记录

开发副本：WSL `/home/lenovo/projects/kelivo`，分支 `feature/device-sync`。
用户设备：Android Kelivo 1.3.1，接受独立测试版；先在 WSL 联调，之后部署用户授权的远程服务器。
提交目标：`https://github.com/xxs9331/kelivo`；手机使用 Kelivo，电脑优先使用 DSH / DS Bot，共享同步服务与对话历史。两端 Kelivo 仍可使用同一协议同步。

## Open WebUI 参考
参考官方文档 `https://docs.openwebui.com/reference/api-flow/` 的会话持久化与消息身份：会话 ID、消息 ID 固定，模型请求与聊天保存分别处理。Kelivo 的版本组、流式状态和本地排序使用现有结构，不机械转换成 Open WebUI 的 `parentId/childrenIds` 消息树。当前实现仍是轻量同步服务，不要求安装 Open WebUI；保留本地数据库才能离线写入，另需 outbox、幂等重试、删除意图和增量游标。

## 首期交付
对话/消息双向增量同步、删除传播、设备配对、手动/启动同步。默认不传 API Key、设备路径、临时会话。附件二进制、其他业务实体、SSE 与 E2EE 是后续阶段。

## 测试版使用
- Android debug 包名 `com.psyche.kelivo.sync`，名称 `Kelivo Sync Test`，可与正式版并存。
- Windows 使用 `--dart-define=KELIVO_SYNC_TEST=true` 构建；主数据库放在应用支持目录的 `sync-test` 子目录，本地偏好使用独立前缀。
- 新测试版首次为空库。先从正式版导出备份，再在测试版导入；模型供应商配置仍在每台设备本地管理。
- 进入设置「多设备同步」，填写服务器地址与一次性配对码。另一端可扫描已配对设备生成的二维码，或使用服务端重新生成的配对码。
- 进程存活时每 60 秒同步一次，启动/返回前台和手动操作也会触发；不承诺手机系统杀死进程后的后台同步。
- 两端追加的新消息均保留；同一消息的编辑按时间与设备 ID 裁决。并发修改会话标题、置顶或模型覆盖时保留配置冲突副本；副本不重复聊天正文。
- 删除会传播，已删除会话的旧 ID 不恢复。先用少量测试聊天验证双向新增与删除，再导入主要历史。

## WSL 当前运行位置
服务二进制 `/home/lenovo/.local/share/kelivo-tools/kelivo-sync`，
数据库 `/home/lenovo/.local/share/kelivo-sync/sync.db`，监听 `127.0.0.1:8787`。
仅供本机调试；手机不能将自己的 `127.0.0.1` 当作服务器地址。
需局域网连接或之后部署 HTTPS 服务，才能进行手机与电脑真机联调。

生成首台设备的配对码：

```sh
/home/lenovo/.local/share/kelivo-tools/kelivo-sync \
  -db /home/lenovo/.local/share/kelivo-sync/sync.db pair-code
```

本机 HTTP 连接需在同步设置中明确开启局域网 HTTP 测试选项。公网只使用 HTTPS。

## 对交接方案的修正
- push 回执只确认 outbox，绝不能跳跃推进 pull 游标，否则会漏掉两个请求之间其他设备写入的记录。
- LWW 相同时间用设备 ID 裁决；重复版本不产生新变更。删除会话后，旧会话 ID 不允许复活，恢复须使用新 ID。
- 快照必须在一致读事务中捕获记录和游标。
- 幂等键按设备隔离，并验证重复请求内容相同；配对码限流且仅存哈希，设备 token 仅存哈希。
- 客户端首轮必须采集启用同步前已有数据；远端应用不重新进入本地 outbox。
- 恢复锁是进程级/文件级生命周期机制，不能照文档重复获取已持有的 business lease。
- 长消息 pull 页同时受记录数和正文大小约束，客户端仍按实际返回的游标继续。
- 备份中的同步状态被清理，导入端重新建立本地基线，不继承其他设备的 outbox 或游标。

## 验证门槛
Go 服务端单元/HTTP 集成/竞态测试；Dart 格式、静态分析、Flutter 测试；两端离线修改、并发追加、删除、重复推送与中断恢复。最后才做 Android 测试版及真机联调。
# DSH / DS Bot 互通

新增 DS Bot 插件适配，源码在本机 `/home/lenovo/projects/deepseek-bot-sync`。
目标是共享用户/助手对话上下文：同步不会触发推理、工具或远程操作。
DSH 使用公开 Session API 导入真实消息；Kelivo 使用现有同步引擎和请求构建链。
模型配置、密钥、系统提示、Bot 权限和附件不随聊天记录复制。

2026-10-13 的独立模拟实例验证已通过：DSH 的实际模型请求读取手机用户与助手历史；
Kelivo 的实际 HTTP 模型请求包含 DSH 新回复。DS Bot 插件 437 项测试、36 步原有流程冒烟通过。
这些结果是 WSL 测试环境的验证，尚不代表 Windows 原生界面或安卓真机已完成验收。

DS Bot 设置新增「Kelivo 同步」，可配对、立即同步、同步 Bot 私聊、导入手机对话。
导入手机对话创建一个新 Bot，选择模型后再由用户主动继续聊天。
手机删除对话不会删除电脑 Bot；DSH 保留审计记录，手机消息编辑更新模型上下文。
编辑已压缩或归档的历史通过当前上下文的明确修正说明处理。
