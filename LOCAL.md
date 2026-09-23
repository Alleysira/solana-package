# Agave 4.3.0 本地容器可行性验证

日期：2026-09-22。目录：`/Users/jie.ma/solana-diff-testing/solana-package`。

## 状态

后续清理：用户确认后已执行 `docker compose -f compose.agave.yaml down`，删除本项目的两个容器、容器内链数据和项目网络；源码、镜像及验收记录保留。以下停机与资源描述为清理前的历史记录。当前已无容器可用 `start` 恢复，重新部署需先满足磁盘余量要求，再运行 `./start-compose.sh`；这会创建新的链状态，旧端点及交易不再在线。

旧 `solana-local` enclave 已按用户要求删除，旧端口不再有效。
**4.3.0 Linux ARM64 镜像已从源码构建成功，Compose 部署和功能验收通过。**
验收后因磁盘只剩约 4.9 GiB、ledger 仍在增长，已于 18:56（北京时间）主动停止本项目的两个服务。容器、链数据和镜像均保留，没有删除；当前端点不在线，恢复方法见“资源与生命周期”。
这是本地单 test-validator 的可行性验证，不是异构多验证者网络。
Kurtosis 部署尚未打通：Agave 4.3.0 的 Linux 路径要求 io_uring，而本机 Docker 默认 seccomp 拒绝相关调用；Kurtosis 1.20.0 没有按服务配置自定义 seccomp 的字段。
实际部署采用 Compose 和精细 seccomp，未启用 privileged，也未修改 Docker 全局配置。Compose 成功不能作为 Kurtosis 成功的证据。
旧版成功记录保存在 [LOCAL-2.2.15.md](./LOCAL-2.2.15.md)，不能作为新版通过的证据。

| 项目 | 验收结果 |
| --- | --- |
| 镜像 | `solana-diff/agave:4.3.0-arm64`，Linux ARM64，348,346,972 bytes（约 332 MiB） |
| Image ID | `sha256:efbc4005ea2a3890d51e148f6862ff897c715e3fdb6b1785be6812b03e971b22` |
| 二进制 | `solana-test-validator 4.3.0 (src:825efd18; feat:c9ad34d2, client:Agave)` |
| RPC | `http://127.0.0.1:32769` |
| WebSocket | `ws://127.0.0.1:32770` |
| Faucet API | `http://127.0.0.1:32768` |
| Explorer | [打开本地 Explorer](http://127.0.0.1:32771/?cluster=custom&customUrl=http%3A%2F%2F127.0.0.1%3A32769) |

端口均只发布到宿主机 loopback，重建容器后可能变化。上述 URL 对应此次已停止的运行，恢复后请重新查询端口。

## 构建

Agave tag `v4.3.0`，commit `825efd18292aff6ffcf9daa0f7612f21b3531a72`，Rust `1.97.1`。
官方不再发布 4.x Docker 镜像，也没有 Linux ARM64 release tarball；因此采用原生 ARM64 Linux 源码构建，不使用 macOS 程序或 amd64 仿真。

```bash
cd /Users/jie.ma/solana-diff-testing
git clone --depth 1 --branch v4.3.0 https://github.com/anza-xyz/agave.git agave
cd solana-package
./build-agave.sh
```

源码已经存在时不再 clone。脚本验证源码提交且拒绝 tracked 修改。
本机网络的 Zscaler 根证书需通过临时 BuildKit secret 提供给 npm 和 Cargo/Git，已验证 TLS 校验通过且 API 构建成功：

```bash
BUILD_CA_PEM="$(security find-certificate -c 'Zscaler Root CA' -p /Library/Keychains/System.keychain)" ./build-agave.sh
```

该命令只读取公钥证书，不读取私钥，不改变系统信任。Cargo 阶段临时合并 CA bundle，构建完成时清除；不把此 secret 带入最终运行镜像。
没有这类代理的网络直接使用 `./build-agave.sh`；没有禁用 TLS 证书校验。

多阶段 `Dockerfile.agave` 使用上游 `cargo-install-all.sh`，保留其 DCOU feature 隔离检查。
仅编译 test-validator、CLI、keygen、installer；不编译独立多验证者运维工具、ledger-tool、SBF 平台工具或 SPL Token CLI。
镜像保留包自带的 Node API。`/fund-usdc` 等 SPL Token 端点不支持，公网账户/程序克隆和 reset API 不在此次验收范围内。

基础 Debian 和 Node 镜像固定 digest，源码 commit、Rust 版本、Cargo.lock 固定。
APT 软件源与 rustup 下载服务仍是外部依赖，本构建不承诺逐字节可复现。
使用 release profile，但关闭 LTO、调试符号、增量编译，默认 2 个并行编译任务；这不是生产性能基线。
`program-runtime/src/program_cache_entry.rs` 的 SBF JIT 编译只在非 Windows x86-64 上启用。
本次 ARM64 构建不能覆盖该 JIT 路径；研究 SBF/JIT 行为时仍需要匹配生产架构的 Linux x86-64 环境。
构建缓存使用 `solana-agave430-*` 独立 cache ID，不带入运行镜像。

资源条件：宿主机 Apple Silicon / 16 GiB RAM；OrbStack 为 8 CPU / 约 7.808 GiB RAM。
建议构建前预留至少 20 GiB 磁盘。脚本最低 10 GiB 才尝试，并每 5 秒检查可用空间，低于 3 GiB 时取消构建、保留缓存；这不是对所需峰值空间的保证。
检查路径为 workspace 文件系统，仅适用于本机 workspace 与 OrbStack 数据共用 APFS 卷的布局。
不会自动删除其他镜像、enclave、容器或卷。
构建成功日志中的 release 编译时间为 18 分 28 秒；含依赖下载的对应构建步骤约 23 分 36 秒，Rust 工具链下载另约 11 分钟。这些是本机观测，不是稳定耗时承诺；缓存、网络及失败重试会影响总耗时。

`seccomp/agave.json` 基于 Docker 28.5.2 对应的默认配置，仅增加三个 io_uring 调用；非 root、drop all capabilities、no-new-privileges 条件下的内核探针与实际 Agave 验收均已通过。默认 seccomp 下实际 4.3.0 则在 `fs/src/dirs.rs:27` 的 io_uring 检查处 panic。详见 [seccomp 说明](./seccomp/README.md)。新增 syscall 仍扩大内核攻击面，不代表完成安全审计。

`node --test test-build-guards.mjs` 的 6 项隔离测试已通过：非法数值、启动前磁盘不足、源码修改拒绝、macOS Bash 3.2 的无 secret 构建参数、Docker 失败状态传播、运行中磁盘阈值取消。测试使用 mock 命令，不启动或删除真实 Docker 环境。

## 部署与验收

实际运行入口为 `start-compose.sh` 与 `compose.agave.yaml`，保留上游包的 Node Faucet API 和 Explorer。
Compose 与 `local-params.yaml` 均关闭公网账户克隆、配置 100 万测试 SOL、`RUST_LOG=warn`。
4.3.0 使用 `--limit-blockstore-size 10000`，单位是 shred 数量，不是 MiB，也不限制全部日志与账户库大小。
新参数统计 data + coding shreds；旧 `--limit-ledger-size` 仅统计 data shreds，两者相同数值不代表相同保留窗口。

```bash
cd /Users/jie.ma/solana-diff-testing/solana-package
./start-compose.sh
node verify-local.mjs --compose
```

Compose 启动脚本要求镜像已缓存，不拉取镜像，默认至少 8 GiB 余量。本次在全部镜像缓存、检查磁盘后使用 `MIN_FREE_GIB=6 ./start-compose.sh` 启动；这不是降低默认阈值的建议。验收后余量由约 5.6 GiB 降到 4.9 GiB，已主动停止服务，当前余量不能通过默认启动检查。

验收脚本要求宿主机 Node.js 22 或更新版本，本机为 24.14.0。它检查 4.3.0、Linux ARM64、源码提交、容器安全配置、RPC health、finalized slot 增长、WebSocket、API `/ping`、空投 10 SOL、带 Memo 的 1 SOL 转账、最终余额及交易成功，并通过 API `/fund` 向另一测试账户空投 1 SOL、验证最终到账。
Memo v4 验证程序执行成功日志、executable 标记和 BPF upgradeable loader 所有者，用来覆盖实际 SBF 执行；不据此声称覆盖 x86-64 JIT。
密钥由容器内 `solana-keygen` 生成于临时目录，不使用真实钱包，退出时清理。

2026-09-22 18:51:40（北京时间）的完整验收通过，机器可读结果为 [verification-agave43.json](./verification-agave43.json)。finalized slot 从 223 增至 320，RPC feature-set 为 `3383571666`，收款账户最终余额为 1,000,000,000 lamports。
另以 Playwright / Chrome 检查桌面 1440 × 1000 和移动端 390 × 844：每个视口均观察到 11 个本地 RPC 响应、零 RPC 错误；交易详情显示 Success、FINALIZED 和 Memo 文本。浏览器交易检查使用较早一轮成功交易，不是 JSON 中最后一笔。
截图保存在 `/tmp/solana-agave43-desktop.png`、`/tmp/solana-agave43-mobile.png`、`/tmp/solana-agave43-transaction.png`，属于临时证据，不承诺重启后保留。上游 Explorer 移动端部分长字段仍有截断，本次未修改其 UI。

## 资源与生命周期

| 项目 | 配置 / 实测 |
| --- | --- |
| 宿主机 / VM | Apple Silicon 8 核、16 GiB RAM；OrbStack 8 CPU、约 7.808 GiB RAM |
| Validator 限额 | 4 CPU、4 GiB RAM |
| Explorer 限额 | 1 CPU、768 MiB RAM |
| Validator 低负载采样 | 约 569–833 MiB RAM，111–124% Docker CPU |
| Explorer 采样 | 约 96–166 MiB RAM |
| Ledger 采样 | 初期约 333–489 MiB，约 7 分钟内进一步增至 1.2 GiB，主要为 RocksDB |

上述是短期采样范围，不是运行峰值、最低配置或长期稳定性结论；Docker CPU 100% 约为一个逻辑 CPU。VM、构建缓存和其他基础服务开销未包含在两项容器采样中。容器日志每个最多保留 2 × 10 MB，但 `--limit-blockstore-size` 不限制账户库和整个 ledger 目录；当前低磁盘余量不适合长期无人值守运行。没有自动执行缓存或镜像清理。

查看健康状态和实时端口：

```bash
docker compose -f compose.agave.yaml ps
docker compose -f compose.agave.yaml port solana-validator 8899
docker compose -f compose.agave.yaml port solana-explorer 3000
```

只停止本项目，保留容器及其可写层；之后可以启动原容器：

```bash
docker compose -f compose.agave.yaml stop
docker compose -f compose.agave.yaml start --wait
```

此次已执行上述 scoped stop，未执行删除；停止前两项服务健康检查通过，validator 未发生 OOM。停止不会释放构建缓存或容器已占磁盘。建议恢复到至少 8 GiB 可用空间再启动；原生 Compose `start` 不包含脚本的磁盘保护，启动前必须自行检查。此次没有验收 stop/start 后的 ledger 恢复流程，恢复后应重新运行 `node verify-local.mjs --compose` 并查询端口。

Ledger 位于容器可写层，没有持久卷：普通 stop/start 保留该层，但 `down` 或强制重建会丢失链状态；即使保留状态，测试余额和短期交易历史也不应当作持久实验数据库。

## Kurtosis 边界与未覆盖项

`local-params.yaml` 和 launcher 已适配镜像、faucet/env 参数及新 CLI 选项，但 `start-local.sh` / 不带 `--compose` 的验收入口仍是 Kurtosis 路径，**不能在本机默认 seccomp 下成功部署此镜像**。不要把它们当作上面的复现命令。
要继续 Kurtosis 路线，需要给其 Docker backend 增加受控的每服务 seccomp 支持，或由用户明确接受仅临时 validator 的 privileged 模式；此次均未实施，也没有重建旧 enclave。不要运行上游 README 的全局 `kurtosis clean -a`。

本次没有验证多验证者共识、Agave/Firedancer 差分、x86-64 JIT、压力/耐久性或生产安全性。USDC API 不支持，公网克隆与 reset API 未验收。新镜像只存在于本机 Docker，未推送到任何 registry。
