#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/build.yml"
CI="$ROOT/.github/workflows/ci.yml"
COMPOSE="$ROOT/docker-compose.yml"
EBPF_COMPOSE="$ROOT/docker-compose.ebpf.yml"
CLEANUP="$ROOT/.github/workflows/cleanup-workflow-runs.yml"
README="$ROOT/README.md"

assert_contains() {
  local file="$1" pattern="$2"
  grep -Fq -- "$pattern" "$file" || {
    echo "missing '$pattern' in $file" >&2
    exit 1
  }
}

assert_not_contains() {
  local file="$1" pattern="$2"
  if grep -Fq -- "$pattern" "$file"; then
    echo "unexpected '$pattern' in $file" >&2
    exit 1
  fi
}

# 网络请求必须有边界重试与超时。
assert_contains "$WORKFLOW" '--retry 3'
assert_contains "$WORKFLOW" '--retry-all-errors'
assert_contains "$WORKFLOW" '--connect-timeout 15'
assert_contains "$WORKFLOW" '--max-time 120'
assert_contains "$WORKFLOW" 'permissions:'
assert_contains "$WORKFLOW" 'contents: read'
assert_contains "$WORKFLOW" 'contents: write'
assert_contains "$WORKFLOW" 'packages: write'
assert_not_contains "$WORKFLOW" 'actions/checkout@v4'
assert_not_contains "$WORKFLOW" 'docker/setup-qemu-action@v3'
assert_not_contains "$WORKFLOW" 'docker/setup-buildx-action@v3'
assert_not_contains "$WORKFLOW" 'docker/login-action@v3'
assert_not_contains "$WORKFLOW" 'docker/build-push-action@v6'
assert_contains "$WORKFLOW" 'actions/checkout@11d5960a326750d5838078e36cf38b85af677262'

# 自动版本检查每 6 小时运行一次，避免无必要的高频构建检查。
# shellcheck disable=SC2016
assert_contains "$WORKFLOW" 'cron: "0 */6 * * *"'
assert_not_contains "$WORKFLOW" 'cron: "0 */1 * * *"'

# 同一分支协调运行顺序，避免旧的定时运行使用过期 checkout 重写版本记录。
# shellcheck disable=SC2016
assert_contains "$WORKFLOW" 'group: build-${{ github.workflow }}-${{ github.ref }}'
# shellcheck disable=SC2016
assert_contains "$WORKFLOW" 'cancel-in-progress: ${{ github.event_name == '\''workflow_dispatch'\'' }}'
assert_not_contains "$WORKFLOW" 'cancel-in-progress: false'
# shellcheck disable=SC2016
assert_contains "$WORKFLOW" 'ref: ${{ github.ref_name }}'

# 构建记录与镜像摘要必须可追溯。
assert_contains "$WORKFLOW" 'source_commit'
assert_contains "$WORKFLOW" 'dockerfile_sha256'
assert_contains "$WORKFLOW" 'ghcr_digest'
assert_contains "$WORKFLOW" 'dockerhub_digest'
assert_contains "$WORKFLOW" 'sbom: true'
assert_contains "$WORKFLOW" 'provenance: mode=max'
assert_contains "$ROOT/scripts/merge-channel-manifests.sh" 'docker buildx imagetools inspect'
assert_contains "$ROOT/scripts/merge-channel-manifests.sh" 'EXPECTED_PLATFORMS'
assert_contains "$ROOT/scripts/update-version-record.sh" 'source_commit'
assert_contains "$ROOT/scripts/update-version-record.sh" 'ghcr_digest'
assert_contains "$ROOT/scripts/update-version-record.sh" 'dockerhub_digest'
assert_contains "$ROOT/scripts/update-version-record.sh" 'source_branch'
assert_contains "$WORKFLOW" 'scripts/prepare-ebpf-dockerfile.sh'
assert_contains "$WORKFLOW" 'file: src/Dockerfile.ebpf'
assert_contains "$WORKFLOW" 'ebpf_dockerfile_sha256'
assert_contains "$WORKFLOW" "grep -Fx 'with_ebpf'"
assert_contains "$WORKFLOW" "grep -Fx 'CGO: disabled'"
# shellcheck disable=SC2016
assert_contains "$ROOT/scripts/prepare-ebpf-dockerfile.sh" 'FROM --platform=$BUILDPLATFORM'
assert_not_contains "$ROOT/scripts/prepare-ebpf-dockerfile.sh" 'ENV CGO_ENABLED=1'
assert_not_contains "$ROOT/scripts/prepare-ebpf-dockerfile.sh" 'make -C common/ebpf generate'
assert_contains "$WORKFLOW" 'prepare_stable:'
assert_contains "$WORKFLOW" 'prepare_testing:'
assert_contains "$WORKFLOW" 'merge_stable:'
assert_contains "$WORKFLOW" 'merge_testing:'
assert_contains "$WORKFLOW" 'needs.prepare_stable.outputs.ebpf_dockerfile_sha256'
assert_contains "$WORKFLOW" 'needs.prepare_testing.outputs.ebpf_dockerfile_sha256'
assert_contains "$WORKFLOW" '校验稳定版 eBPF 构建特性'
assert_contains "$WORKFLOW" '校验测试版 eBPF 构建特性'
if [[ "$(grep -Fc 'file: src/Dockerfile.ebpf' "$WORKFLOW")" -ne 4 ]]; then
  echo 'stable/testing builds must both use Dockerfile.ebpf for both registries' >&2
  exit 1
fi
# GitHub expressions are intentional literal test patterns.
# shellcheck disable=SC2016
assert_contains "$WORKFLOW" 'platforms: ${{ matrix.platform }}'
# shellcheck disable=SC2016
assert_contains "$WORKFLOW" 'scope=stable-${{ matrix.slug }}'
# shellcheck disable=SC2016
assert_contains "$WORKFLOW" 'scope=testing-${{ matrix.slug }}'
assert_contains "$WORKFLOW" 'push-by-digest=true'
assert_contains "$WORKFLOW" 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02'
assert_contains "$WORKFLOW" 'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093'
# shellcheck disable=SC2016
assert_not_contains "$WORKFLOW" 'stable-build-${{ matrix.slug }}'
# shellcheck disable=SC2016
assert_not_contains "$WORKFLOW" 'testing-build-${{ matrix.slug }}'
assert_contains "$WORKFLOW" 'source_version'

# 用户要求保留从所选移动分支构建，并让 reF1nd 修订覆盖相同短 tag。
assert_contains "$WORKFLOW" 'git clone --depth 1 --branch'
assert_contains "$WORKFLOW" 'stable_docker_tag'
assert_contains "$WORKFLOW" 'testing_docker_tag'
# Literal pattern guards the intended tag mapping.
# shellcheck disable=SC2016
assert_contains "$ROOT/scripts/select-upstream-version.sh" 'docker_tag="${version%%-reF1nd*}"'

# TUN Compose 只保留 TUN 所需权限。
assert_not_contains "$COMPOSE" 'privileged: true'
assert_not_contains "$COMPOSE" '      - ALL'
assert_contains "$COMPOSE" '      - NET_ADMIN'
assert_contains "$COMPOSE" '/dev/net/tun:/dev/net/tun'
assert_not_contains "$COMPOSE" '      - BPF'
assert_not_contains "$COMPOSE" '      - PERFMON'
assert_not_contains "$COMPOSE" '      - IPC_LOCK'
assert_not_contains "$COMPOSE" '      - NET_RAW'
assert_not_contains "$COMPOSE" '    cgroup: host'
assert_contains "$COMPOSE" 'no-new-privileges:true'
assert_contains "$COMPOSE" 'restart: unless-stopped'

# eBPF Compose 只保留实测需要的 eBPF 权限，不挂载 TUN。
assert_not_contains "$EBPF_COMPOSE" 'privileged: true'
assert_not_contains "$EBPF_COMPOSE" '      - ALL'
assert_not_contains "$EBPF_COMPOSE" '      - SYS_ADMIN'
assert_not_contains "$EBPF_COMPOSE" '      - NET_RAW'
assert_not_contains "$EBPF_COMPOSE" '      - IPC_LOCK'
assert_not_contains "$EBPF_COMPOSE" '/dev/net/tun:/dev/net/tun'
assert_contains "$EBPF_COMPOSE" '      - NET_ADMIN'
assert_contains "$EBPF_COMPOSE" '      - BPF'
assert_contains "$EBPF_COMPOSE" '      - PERFMON'
assert_contains "$EBPF_COMPOSE" '    cgroup: host'
assert_contains "$EBPF_COMPOSE" '      memlock:'
assert_contains "$EBPF_COMPOSE" '        hard: -1'
assert_contains "$EBPF_COMPOSE" 'no-new-privileges:true'
assert_contains "$EBPF_COMPOSE" 'restart: unless-stopped'

# 清理仅针对已完成且超过保留期的运行，并保留最近一批记录。
assert_contains "$CLEANUP" 'set -euo pipefail'
assert_contains "$CLEANUP" 'status == "completed"'
assert_contains "$CLEANUP" 'RETENTION_DAYS'
assert_contains "$CLEANUP" 'KEEP_LATEST_RUNS'
assert_contains "$CLEANUP" 'Keeping one of the latest'
assert_contains "$CLEANUP" 'sort -r -k2,2'

# 独立 CI 必须执行脚本、策略与 Compose 校验。
assert_contains "$CI" 'tests/test-select-version.sh'
assert_contains "$CI" 'tests/test-cleanup-policy.sh'
assert_contains "$CI" 'tests/test-project.sh'
assert_contains "$CI" 'shellcheck scripts/*.sh tests/*.sh'
assert_contains "$CI" 'tests/test-prepare-ebpf-dockerfile.sh'
assert_contains "$CI" 'tests/test-merge-channel-manifests.sh'
assert_contains "$CI" 'actionlint .github/workflows/*.yml'
assert_contains "$CI" 'sha256sum -c -'
assert_not_contains "$CI" 'actions/checkout@v4'
assert_contains "$CI" 'docker compose config --quiet'
assert_contains "$CI" 'docker compose -f docker-compose.ebpf.yml config --quiet'

# README 只保留镜像与部署所需的精简使用说明。
assert_contains "$README" 'ghcr.io/cary17/sing-box:latest'
assert_contains "$README" 'ghcr.io/cary17/sing-box:testing'
assert_contains "$README" 'with_ebpf'
assert_contains "$README" 'CGO: disabled'
assert_contains "$README" '统一 TC eBPF 入站'
assert_contains "$README" 'docker compose up -d'
assert_contains "$README" 'docker compose -f docker-compose.ebpf.yml up -d'
assert_contains "$README" 'sing-box tools ebpf status --mode local'
assert_contains "$README" 'sha256:<manifest-digest>'
assert_contains "$README" 'force_build'
assert_not_contains "$README" 'Testing 当前仍是较早的 cilium 双数据路径实现'
assert_not_contains "$README" 'Stable 与 Testing 配置差异'
assert_not_contains "$README" '构建与供应链记录'
assert_contains "$EBPF_COMPOSE" 'image: ghcr.io/cary17/sing-box:latest'
assert_not_contains "$EBPF_COMPOSE" 'image: ghcr.io/cary17/sing-box:testing'

echo 'project checks passed'
