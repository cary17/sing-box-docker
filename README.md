# reF1nd Sing-Box Docker

自动构建 Stable 与 Testing 多架构镜像。

## 镜像

- Stable：`ghcr.io/cary17/sing-box:latest` / `cary17/sing-box:latest`
- Testing：`ghcr.io/cary17/sing-box:testing` / `cary17/sing-box:testing`

支持 `amd64`、`arm64`、`386`、`arm/v7`、`arm/v6`。

## 使用

将 sing-box 配置放入 Compose 文件同目录的 `conf/`，然后启动：

```bash
mkdir -p conf
docker compose up -d
docker compose exec sing-box sing-box version
docker compose logs --tail 100 sing-box
```

更新镜像：

```bash
docker compose pull
docker compose up -d
```

生产环境可使用摘要固定镜像：

```yaml
image: ghcr.io/cary17/sing-box@sha256:<manifest-digest>
```

GitHub Actions 会自动检测 Stable/Testing 新版本；手动运行时可选择渠道并使用 `force_build` 强制构建。
