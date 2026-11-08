# Home tailnet 验证夹具

本工具仅在 mini 自己的 `100.122.16.85` 网卡上暴露一个临时 bearer gate，后面是工具独占的 `127.0.0.1`、随机端口、临时数据库 `loro dev --protocol http1`。不接受真实 hub URL、token 或现有数据库，不读取任何钥匙串。

先完成仓库 `pnpm install`。CLI 依赖与私有状态只放在已忽略的 `.artifacts/home-tailnet/`：

```sh
mkdir -p .artifacts/home-tailnet/hub-deps
npm install --prefix .artifacts/home-tailnet/hub-deps --no-audit --no-fund @loro-dev/loro-cli
node --experimental-strip-types verification/home-tailnet/hub.mjs
```

调用前按仓库约定持有 `/tmp/lody-ios-mac-heavy.lock`，遵守负载上限和单模拟器规则。此工具不启动、关闭或改动模拟器。启动输出只有临时端点和状态文件路径，没有 token。`.artifacts/home-tailnet/state.json` 权限为 0600，包含本次随机邀请，供本轮 UI 驱动在内存中读取并填入真实加入表单；不要把它写入报告或提交。

夹具数据：

| 机器                      | 别名        | OS / 版本                      | 心跳         | 项目         | 会话                 |
| ------------------------- | ----------- | ------------------------------ | ------------ | ------------ | -------------------- |
| Online Mini (`home-mini`) | Mini Online | darwin / 0.109.0-lan.synthetic | 每 15 秒发送 | Mini Project | Mini Tailnet Session |
| Offline NUC (`home-nuc`)  | NUC Offline | linux / 0.109.0-lan.synthetic  | 从不发送     | NUC Project  | NUC Tailnet Session  |

两者都有真实序列化 Flock 元数据、机器目录、项目与合成 Loro 历史。在线机器通过真实 Streams RPC 回应 `machine/ping`；离线机器不运行 RPC responder。`machineStatus` 的机器资料与 heartbeat 投影仍由生产 runtime 处理。hub 延迟经过真实 tailnet HTTP HEAD 路径。空 workspace 设置流用于正常 metadata 就绪，不连 Cloud 或真实模型。

真实验收应从干净测试安装加入本次邀请，然后：

1. 首页切换 By Machine，验证两台机器及各自项目/会话、机器标题折叠与恢复；旧偏好 3 恢复另由离线 case 覆盖。
2. 设置账户行看到 `Home Synthetic`、hub 地址与延迟；账户页 Hub 行进入连接详情。
3. 连接页看到 hub 延迟、两台机器的别名/原名/OS/版本，Online Mini 心跳在线并有 ping，Offline NUC 离线；presence 与同步流状态分别显示。
4. 报告保留截图及无凭据的 `seed.json`、`events.jsonl` 必要片段，不复制 `state.json`。

按 Ctrl-C 或向启动输出 state 所记的本进程 PID 发送 SIGTERM。工具关闭自有 gate、所有 proxy sockets、heartbeat、RPC 读，以及自有 loro 子进程，再删除包含邀请的 `state.json` 和临时 SQLite 目录（含 WAL/SHM）。`events.jsonl` 最后应出现 `stopped` / `credentialsAndDatabaseRemoved: true`。检查 `seed.json` 记录的端口拒绝连接，再删除 `.artifacts/home-tailnet/hub-deps`。不要 kill 其他任务的进程或删除其他任务的锁。
