# 本地 Solana 环境运行记录

> 历史记录：此处的 2.2.15 enclave 已于 2026-09-22 18:00 按用户要求删除。
> 下文的旧端口、链状态及“当前运行”描述仅记录当时验收，不再有效。新状态见 `LOCAL.md`。

日期：2026-09-22。目录：`/Users/jie.ma/solana-diff-testing/solana-package`。

## 当前状态与入口

已部署成功并完成 RPC、WebSocket、交易与浏览器验收，服务保持运行。

| 服务 | 当前宿主机地址 |
| --- | --- |
| JSON-RPC | http://127.0.0.1:32780 |
| WebSocket | ws://127.0.0.1:32781 |
| Faucet API | http://127.0.0.1:32779/ping |
| Explorer（连接本地链） | [打开本地 Explorer](http://127.0.0.1:32782/?cluster=custom&customUrl=http%3A%2F%2F127.0.0.1%3A32780) |

Kurtosis enclave：`solana-local`，UUID：`9174011dea234526be10a167f4df4105`。

端口由 Kurtosis 动态分配，重建后会变化。当前端口应以以下命令为准：

```bash
kurtosis enclave inspect solana-local
kurtosis port print --format number solana-local solana-validator rpc
kurtosis port print --format number solana-local solana-validator ws
kurtosis port print --format number solana-local solana-validator api
kurtosis port print --format number solana-local solana-explorer explorer
```

这只是一个 Agave `solana-test-validator` 加 Explorer 的本地开发环境，不是 Agave/Firedancer 异构多验证者网络。没有向公网 Solana 网络发送交易，也不需要真实 SOL。

## 版本与配置

上游仓库：`https://github.com/0xBloctopus/solana-package.git`。
基线 commit：`52d11f0d30cf5f7850c4e2d21d560c1f9e9e64c8`，带本文记录的本地修改。

| 项目 | 实测值 |
| --- | --- |
| 主机 | Apple Silicon，8 个物理核心，16 GiB RAM |
| Docker | OrbStack，Docker 28.5.2，Linux aarch64 |
| Docker VM 配额 | 8 CPU，约 7.808 GiB RAM |
| Kurtosis CLI | 1.20.0 |
| Validator / Solana CLI | Agave 2.2.15，`src:00000000`，feature-set `798020478` |
| 宿主机 Solana CLI | 未安装，使用容器内 CLI |
| 自动验收脚本 | 宿主机 Node.js 22/24，使用内置 fetch、WebSocket，无 npm 项目依赖 |

镜像标签 `1.0.2` 不是 Solana 客户端版本。二进制未提供可用的源码 commit，镜像 digest 才是此次二进制产物的精确标识。

| 镜像 | 锁定的多架构 index digest | ARM64 压缩层总量 | Docker 报告镜像大小 |
| --- | --- | --- | --- |
| `tiljordan/solana-test-validator:1.0.2` | `sha256:f6594b3b3aadc2d6bd49b27ad0721db64f36a9cea4dbf72583c33ecbe6715309` | 892,792,833 bytes | 3.16 GB |
| `tiljordan/solana-explorer:1.0.6` | `sha256:91ab7d1a7a24101f3950e027c97bbec9c093e4059a68cba49a923d8876e996b8` | 731,798,208 bytes | 3.07 GB |

两者实际运行架构均为 ARM64，没有启用 amd64 仿真。这些是较旧的第三方镜像，不代表当前 Agave 最新版本，不应用于正式客户端差分结论或生产部署。

`local-params.yaml` 关闭公网账户克隆，配置 100 万测试 SOL 的 faucet、`RUST_LOG=warn` 和 `--limit-ledger-size 10000`。10,000 是 shred 数量，不是 MB，也不限制整个容器、账户库或所有日志的总大小。

launcher 只做两处兼容扩展：透传可选 `validator_params.env_vars`，以及允许覆盖 `validator_params.faucet_sol`。未提供这些参数时保留上游行为。上游的 2 万亿 SOL faucet 参数在初次实测中并未阻止启动，本地改为 CLI 默认值属于配置收敛，不作为已确认的客户端 bug。

## 验收结果

2026-09-22 17:46:28（Asia/Shanghai），最终配置下的 `node verify-local.mjs` 通过：

- `getHealth` 返回 `ok`，`getVersion` 返回 Agave 2.2.15。
- finalized slot 从 61 增至 127。
- `slotSubscribe` 收到 slot 94 的通知。
- 容器内临时发送者空投 10 SOL，随后转出 1 SOL。
- 交易状态为 `finalized`，`getTransaction.meta.err` 为 `null`。
- 接收者余额为 1,000,000,000 lamports。
- API `/ping` 返回 `pong`，Explorer HTTP 返回 200。
- Explorer 交易详情页另行确认该笔 1 SOL 转账显示 `Success / FINALIZED`。
- 临时密钥已清理，没有修改宿主机钱包或默认 RPC 配置。

当前 genesis hash：

```text
CeiFpgYrLUCLu7zaEQaoDcYWJk635UvNqcxzt4ycDkjC
```

测试接收者与交易签名：

```text
2XdRHAQUyUWM5eP55xxHYp8GgVzaPaybXz3k9RDUxQxB
2vsrd9EeEDzfQkFNyy3Njfa8PytWe99MzZGcMu1UWje4L4dqGsQu6JzPGsKdCnXrgb9oKF1PjiJsaq1ZZ8hQUdev
```

这些属于当前一次性链状态，重建或 ledger 裁剪后不能保证仍可查询。

另外使用 Playwright 1.63.0 与本机 Chrome 检查了 1440×1000、390×844 两个视口。全新浏览器上下文通过上面的 Custom RPC URL 成功获取本地 `getEpochInfo`，slot 随时间增加，没有观察到这些本地 RPC 响应中的 JSON-RPC 错误。桌面布局正常；上游移动端部分长字段有裁切，未修改 Explorer 前端。自动验收脚本本身只验证 Explorer HTTP，浏览器检查是此次另行执行的验收。

重新验收现有环境：

```bash
cd /Users/jie.ma/solana-diff-testing/solana-package
node verify-local.mjs
```

脚本每次使用新账户，产生两笔本地交易。镜像不包含 `solana-keygen`，因此使用容器内 Node.js 标准加密库生成 Ed25519 密钥，以 Solana CLI 支持的 64 字节 keypair JSON 格式写入临时目录，随后由 CLI 签名。密钥不输出，并在测试 shell 退出时清理。

API 只验收了 `/ping`；USDC、程序克隆等扩展端点不在此次通过范围内。关闭公网克隆的配置也不保证上游 USDC mint 已存在。

## 资源观测

以下是启动后数分钟、低负载下的单次采样，不是最低配置或压力测试结果：

| 组件 | CPU（Docker 显示值） | 内存 |
| --- | --- | --- |
| Validator | 约 18.6% | 约 1.31 GiB |
| Explorer | 约 1.16% | 约 135 MiB |

Docker 的 100% 约对应一个逻辑 CPU，不是整台主机的 100%。上述数字不含 OrbStack、Kurtosis 基础服务和宿主机其他应用。validator ledger 采样约 111 MiB，随后仍可能增长。部署和多次配置验证完成后，宿主机可用空间约 10 GiB。

冷启动建议至少留出 15 GiB、最好 20 GiB 以上可用空间。这是针对本包的保守预算，不是最低值。镜像大小、压缩下载量与 APFS 实际空间变化不能直接画等号。

## 启动、更新与停止

当前环境已经运行，不要为了打开 Explorer 再执行部署命令。

首次部署：

```bash
cd /Users/jie.ma/solana-diff-testing/solana-package
bash start-local.sh
```

`start-local.sh` 默认检查 workspace 所在文件系统至少有 15 GiB 空闲；本机 OrbStack 与 workspace 共用 APFS 数据卷。其他机器或远程 Docker 必须单独检查实际 Docker 数据盘。

只有确认两个镜像已完整缓存、Docker 数据盘有余量时，可以显式使用较低的热启动预算：

```bash
MIN_FREE_GIB=8 bash start-local.sh
```

这个覆盖值不会自动检查镜像缓存，不能用于绕过冷下载所需的空间。修改参数后运行同一命令可能重建服务、改变端口并丢失 ledger；本次修改配置后的实际运行就发生了这些变化。先保存需要的实验结果，再重建。

查看日志：

```bash
kurtosis service logs solana-local solana-validator -a
kurtosis service logs solana-local solana-explorer -a
```

停止这一个环境：

```bash
kurtosis enclave stop solana-local
```

明确要丢弃当前链状态时，停止后删除并重新部署：

```bash
kurtosis enclave rm solana-local
MIN_FREE_GIB=8 bash start-local.sh
```

Kurtosis 1.20.0 没有 `enclave start` 子命令，不承诺无损恢复。上游 `persistent` 字段没有配置持久卷，ledger 位于容器内 `/tmp/solana-ledger`。不要把 `persistent: true` 当成数据保护措施。

不要使用上游 README 中的全局 `kurtosis clean -a` 清理本项目；它可能影响其他实验。以上命令不删除 Docker 镜像。

## 首次失败与恢复

首次尝试启动前只有约 5.3 GiB 空闲。16:32:18，OrbStack 日志出现 `StorageFull / No space left on device`，VM 停止后重启，Kurtosis 连接中断。故障发生于镜像准备阶段，不是 validator 执行失败。

随后按用户明确确认的范围清理 Grandine 的构建产物、指定的 13 个 Docker 镜像及 3 个停止的容器；没有执行全局 prune，也未删除挂载的实验目录或数据卷。空间回升至约 18 GiB 后，17:36 再次部署，约 17:41 完成镜像准备并启动，之后进行了上述本地配置调整和验收。

历史错误证据位于 `~/.orbstack/log/vmgr.1.log` 的 2026-09-22 08:32:18 UTC 附近；日志可能轮转，本文保留关键时间与错误，不复制其他实验的完整日志。
