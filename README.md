# reF1nd Sing-Box Docker 镜像自动构建

本仓库自动检测 [reF1nd/sing-box-releases](https://github.com/reF1nd/sing-box-releases) 发布的 Stable/Testing 版本，并从 [reF1nd/sing-box](https://github.com/reF1nd/sing-box) 中所选的移动分支构建多架构 Docker 镜像。

## 镜像地址与标签

### GitHub Container Registry

```bash
ghcr.io/cary17/sing-box:latest           # 稳定版最新
ghcr.io/cary17/sing-box:stable           # 稳定版最新
ghcr.io/cary17/sing-box:testing          # 测试版最新
ghcr.io/cary17/sing-box:v1.13.14         # 稳定版特定基础版本
ghcr.io/cary17/sing-box:v1.14.0-beta.1   # 测试版特定基础版本
```

### Docker Hub

```bash
cary17/sing-box:latest                  # 稳定版最新
cary17/sing-box:stable                  # 稳定版最新
cary17/sing-box:testing                 # 测试版最新
cary17/sing-box:v1.13.14                # 稳定版特定基础版本
cary17/sing-box:v1.14.0-beta.1          # 测试版特定基础版本
```

支持架构：`linux/amd64`、`linux/arm64`、`linux/386`、`linux/arm/v7`、`linux/arm/v6`。

## eBPF 构建状态

- `testing` 镜像基于 sing-box 1.14 分支，使用 `CGO_ENABLED=1` 和 `with_ebpf` 构建；
- `stable` 当前仍基于不含 eBPF 入站的 sing-box 1.13 分支，继续使用上游默认构建；
- 工作流不会维护上游 Dockerfile 的完整副本。每次构建会严格检查上游关键构建行，生成临时 `Dockerfile.ebpf`；上游结构变化时立即失败，等待人工审查；
- 构建完成后必须从镜像的 `sing-box version` 输出确认存在 `with_ebpf` 且显示 `CGO: enabled`，否则不会更新版本记录；
- 版本记录同时保存原始上游 Dockerfile 和临时 eBPF Dockerfile 的 SHA-256。
- Stable 与 Testing 均按五个平台拆成独立 GitHub Actions 矩阵任务并行构建；只有五个平台全部成功后才合并并覆盖最终标签。Stable 仍使用上游原始 Dockerfile，不启用 eBPF。

## 标签与构建语义

- Docker tag 会去掉上游版本中的 `-reF1nd` 及修订号。
- 例如 `v1.13.14-reF1nd.1` 和 `v1.13.14-reF1nd.2` 都发布为 `v1.13.14`。
- 上游发布更高 reF1nd 修订号，表示同一基础版本需要修复，因此新镜像会直接覆盖原短标签。
- `latest`、`stable`、`testing` 以及上述短版本标签都属于可变标签；需要严格锁定部署内容时，请使用镜像摘要（digest）。
- 构建源码来自工作流选择的移动分支，而不是发布二进制包仓库。工作流会记录实际构建时的分支、源码 commit、Dockerfile SHA-256 和镜像 digest，便于追溯。

默认分支对应关系：

| 渠道 | 默认源码分支 | 可手动选择 |
| --- | --- | --- |
| Stable | `reF1nd-stable` | `reF1nd-stable-next` |
| Testing | `reF1nd-testing` | `reF1nd-testing-next` |

## 使用 Docker Compose

仓库提供的 `docker-compose.yml` 默认使用 GHCR 稳定版镜像：

```bash
mkdir -p /opt/sing-box/conf
# 将 sing-box 配置文件放入 /opt/sing-box/conf
docker compose up -d
docker compose ps
```

查看日志和版本：

```bash
docker compose logs --tail 100 sing-box
docker compose exec sing-box sing-box version
```

更新镜像：

```bash
docker compose pull
docker compose up -d
docker image prune -f
```

如需使用测试版，将 Compose 中的镜像改为：

```yaml
image: ghcr.io/cary17/sing-box:testing
```

如需按摘要固定镜像，可使用：

```yaml
image: ghcr.io/cary17/sing-box@sha256:<manifest-digest>
```

摘要可直接从镜像仓库查询。仓库中的 `.github/version/stable.json`、`.github/version/testing.json` 会在采用新版工作流成功构建后补充摘要及源码追溯字段；现有历史记录在下一次成功构建前可能仍只有旧字段。

## 权限说明

Compose 为 TUN、路由及透明代理场景保留以下权限：

- `network_mode: host`：容器直接使用宿主机网络；
- `NET_ADMIN`：管理路由、TUN 和相关网络规则；
- `NET_RAW`：支持可能需要 raw socket 的网络功能；
- `BPF`：加载和管理 eBPF 程序及 map；
- `IPC_LOCK`：允许锁定 eBPF map 所需内存；
- `memlock: -1`：解除容器默认锁定内存上限，避免较大 eBPF map 因 `EPERM` 或 `ENOMEM` 加载失败；
- `cgroup: host`：让容器访问宿主机 cgroup v2 层级；
- `/dev/net/tun`：提供 TUN 设备；
- `no-new-privileges:true`：阻止进程通过 `execve` 获得额外权限。

默认配置不再使用 `privileged: true` 或 `cap_add: ALL`。由于启用了 host 网络并拥有网络管理能力，仍应只运行可信镜像和可信配置。如果部署不使用 TUN、TProxy、路由或 raw socket，可在实际验证后继续移除不需要的 capability 或设备映射。

使用 eBPF 入站前，先切换到 testing 镜像并探测目标内核能力：

```bash
docker compose exec sing-box sing-box version
docker compose exec sing-box sing-box tools ebpf status --mode local
```

第一条命令必须显示 `with_ebpf` 和 `CGO: enabled`。第二条命令的实际加载结果才是兼容性依据，不能只按内核版本推断。探测失败时保留原 TUN 配置并回退到 `stable` 或先前固定的镜像摘要；不要在未验证的主机上直接替换现有透明代理入站。

## 构建与供应链记录

GitHub Actions 在构建时会：

- 为 GitHub API 请求设置超时和有限重试；
- 克隆所选 Stable/Testing 分支，并记录实际 `source_commit`；
- 记录 Dockerfile 的 SHA-256；
- 构建并推送五种架构的 manifest；
- 生成 SBOM 和 BuildKit provenance；
- 将第三方 GitHub Actions 固定到具体 commit SHA；
- 记录构建输出的镜像 digest；
- 使用 `docker buildx imagetools inspect` 校验推送后的多架构清单；
- 将追溯信息写入 `.github/version/stable.json` 或 `.github/version/testing.json`。

需要核对镜像摘要时，可执行：

```bash
docker buildx imagetools inspect ghcr.io/cary17/sing-box:stable
docker buildx imagetools inspect ghcr.io/cary17/sing-box:testing
```

说明：当前流程生成 SBOM 与 provenance，但尚未提供 Cosign 无密钥签名。对于高保证生产环境，建议同时固定镜像 digest，并自行验证所需的来源证明。

## 手动构建

在 GitHub Actions 的 `Build reF1nd Sing-Box Docker Images` 工作流中可以：

- 选择只构建 `stable`、`testing` 或两者；
- 选择对应的 Stable/Testing 上游源码分支；
- 使用 `force_build` 强制重新构建当前检测版本。

版本记录会保存实际选择的 `source_branch`，不会把二进制发布仓库误当作源码仓库。

## 自动化检查

本地校验：

```bash
tests/test-select-version.sh
tests/test-cleanup-policy.sh
tests/test-prepare-ebpf-dockerfile.sh
tests/test-merge-channel-manifests.sh
tests/test-project.sh
actionlint .github/workflows/*.yml
shellcheck scripts/select-upstream-version.sh tests/*.sh
bash -n scripts/select-upstream-version.sh tests/test-select-version.sh tests/test-cleanup-policy.sh tests/test-project.sh
docker compose config --quiet
```

独立 CI 会在脚本、测试、Compose、README 或工作流变更时执行这些检查。
