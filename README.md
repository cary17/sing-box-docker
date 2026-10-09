# reF1nd Sing-Box Docker

手动触发检测并构建 [reF1nd/sing-box](https://github.com/reF1nd/sing-box) 的 Stable 与 Testing 多架构镜像。

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

运行数据保存在 `sing-box-data` 命名卷中，容器重建后保留。首次从旧版 Compose 升级时，如需保留旧容器内的数据，先执行一次迁移：

```bash
docker compose stop
docker cp sing-box:/var/lib/sing-box/. ./sing-box-data-backup
docker compose pull
docker compose create
docker cp ./sing-box-data-backup/. sing-box:/var/lib/sing-box/
docker compose start
```

保留备份直到确认运行正常；`docker compose down -v` 会删除数据卷。首次部署和完成迁移后的日常更新使用下方命令。

更新镜像：

```bash
docker compose pull
docker compose up -d
```

生产环境可使用版本标签固定镜像：

```yaml
image: ghcr.io/cary17/sing-box:v1.14.0
```

仅通过 GitHub Actions 手动触发检测与构建，不再定时检测上游。在 Actions 中选择 `Build reF1nd Sing-Box Docker Images`，点击 `Run workflow`，选择 Stable、Testing 或两者及对应上游分支。默认仅在检测到新版本时构建；勾选 `force_build` 可强制重建。
