#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/build.yml"
CI="$ROOT/.github/workflows/ci.yml"
COMPOSE="$ROOT/docker-compose.yml"
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

# 构建记录与镜像摘要必须可追溯。
assert_contains "$WORKFLOW" 'source_commit'
assert_contains "$WORKFLOW" 'dockerfile_sha256'
assert_contains "$WORKFLOW" 'ghcr_digest'
assert_contains "$WORKFLOW" 'dockerhub_digest'
assert_contains "$WORKFLOW" 'sbom: true'
assert_contains "$WORKFLOW" 'provenance: mode=max'
assert_contains "$WORKFLOW" 'docker buildx imagetools inspect'
assert_contains "$WORKFLOW" 'EXPECTED_PLATFORMS'
assert_contains "$WORKFLOW" 'DOCKERHUB_MANIFEST'
assert_contains "$WORKFLOW" 'ACTUAL_SOURCE_COMMIT'
assert_contains "$WORKFLOW" 'ACTUAL_GHCR_DIGEST'
assert_contains "$WORKFLOW" 'REMOTE_SOURCE_COMMIT'
assert_contains "$WORKFLOW" 'REMOTE_DOCKERHUB_DIGEST'
assert_contains "$WORKFLOW" 'source_branch'

# 用户要求保留从所选移动分支构建，并让 reF1nd 修订覆盖相同短 tag。
assert_contains "$WORKFLOW" 'git clone --depth 1 --branch'
assert_contains "$WORKFLOW" 'stable_docker_tag'
assert_contains "$WORKFLOW" 'testing_docker_tag'
# Literal pattern guards the intended tag mapping.
# shellcheck disable=SC2016
assert_contains "$ROOT/scripts/select-upstream-version.sh" 'docker_tag="${version%%-reF1nd*}"'

# Compose 默认使用最小权限，不再 privileged + ALL。
assert_not_contains "$COMPOSE" 'privileged: true'
assert_not_contains "$COMPOSE" '      - ALL'
assert_contains "$COMPOSE" '      - NET_ADMIN'
assert_contains "$COMPOSE" '      - NET_RAW'
assert_contains "$COMPOSE" 'no-new-privileges:true'
assert_contains "$COMPOSE" 'restart: unless-stopped'

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
assert_contains "$CI" 'shellcheck scripts/select-upstream-version.sh tests/*.sh'
assert_contains "$CI" 'actionlint .github/workflows/*.yml'
assert_contains "$CI" 'sha256sum -c -'
assert_not_contains "$CI" 'actions/checkout@v4'
assert_contains "$CI" 'docker compose config --quiet'

# README 必须说明权限、版本标签覆盖语义和校验方式。
assert_contains "$README" 'NET_ADMIN'
assert_contains "$README" 'reF1nd'
assert_contains "$README" '镜像摘要'
assert_contains "$README" '移动分支'
assert_contains "$README" 'SBOM'
assert_contains "$README" 'host 网络'

echo 'project checks passed'
