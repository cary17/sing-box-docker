# reF1nd Sing-Box Docker

[reF1nd/sing-box](https://github.com/reF1nd/sing-box) 的第三方 Docker 打包，使用[上游发布的 musl 二进制](https://github.com/reF1nd/sing-box-releases/releases)，支持 `amd64`、`arm64`。

## 镜像

- 仓库：`ghcr.io/cary17/sing-box`、`cary17/sing-box`。
- 标签：稳定版 `latest`、`stable`；测试版 `testing`。也可使用具体版本标签固定镜像。

## 使用

将 sing-box 配置放入同目录的 `conf/`；旧版升级请先完成下方的数据迁移。

```bash
mkdir -p conf
docker compose up -d
```

更新：`docker compose pull && docker compose up -d`。运行数据保存在 `sing-box-data` 命名卷；`docker compose down -v` 会删除数据卷。

旧版数据迁移（确认成功前保留备份）：

```bash
docker compose stop
docker cp sing-box:/var/lib/sing-box/. ./sing-box-data-backup
docker compose pull
docker compose create
docker cp ./sing-box-data-backup/. sing-box:/var/lib/sing-box/
docker compose start
```

## 构建

在 GitHub Actions 手动构建，选择 `stable`、`testing` 或 `both`。

- `version` 留空：检测所选渠道最新版本，使用 `force_build` 可强制重建。
- 指定版本（如 `1.14.4`）：须与所选渠道匹配；渠道最新版更新浮动标签和版本记录，旧版仅发布版本标签。

## 许可

本仓库按 [GPL-3.0-or-later](LICENSE) 授权；上游版权及附加命名、关联声明条款原文见 [NOTICE](NOTICE)。

本项目不代表上游官方。sing-box 和镜像内其他组件保留各自版权与许可证；再分发时须保留声明，并提供 GPL 要求的对应源代码。
