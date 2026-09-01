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
assert_contains "$WORKFLOW" 'bash repo-tools/scripts/prepare-ebpf-dockerfile.sh'
assert_contains "$WORKFLOW" 'bash scripts/merge-channel-manifests.sh'
assert_contains "$WORKFLOW" 'bash scripts/update-version-record.sh'
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

# 用户要求保留从所选移动分支构建；带数字修订号时发布完整精确标签。
assert_contains "$WORKFLOW" 'git clone --depth 1 --branch'
assert_contains "$WORKFLOW" 'stable_docker_tag'
assert_contains "$WORKFLOW" 'testing_docker_tag'
assert_contains "$ROOT/scripts/select-upstream-version.sh" 'docker_tag_for_version'
# Literal pattern guards the unversioned reF1nd tag mapping.
# shellcheck disable=SC2016
assert_contains "$ROOT/scripts/select-upstream-version.sh" 'printf '\''%s\n'\'' "${version%%-reF1nd*}"'

# TUN Compose 只保留 TUN 所需权限。
assert_contains "$COMPOSE" '      - ./conf:/etc/sing-box/'
assert_not_contains "$COMPOSE" '      - /opt/sing-box/conf:/etc/sing-box/'
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
assert_contains "$EBPF_COMPOSE" '      - ./conf:/etc/sing-box/'
assert_not_contains "$EBPF_COMPOSE" '      - /opt/sing-box/conf:/etc/sing-box/'
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

# 仓库脚本统一由 Bash 显式调用，不依赖 Git/MCP 保留可执行位。
policy_path_re='(repo-tools/)?(scripts|tests)/[A-Za-z0-9._/-]+\.sh'
policy_caller_re='(^|[[:space:]();&|`])bash[[:space:]]'
policy_checker_re='(^|[[:space:]();&|`])shellcheck[[:space:]]'
# shellcheck disable=SC2016
policy_assign_re='^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*="[^"]*"[[:space:]]*$'

policy_check_paths() {
  local line rest num body match prefix scan
  while IFS= read -r line; do
    rest="${line#*:}"
    num="${rest%%:*}"
    body="${rest#*:}"
    [[ "$body" =~ ^[[:space:]]*# ]] && continue
    if [[ "$1" == shell ]]; then
      # 断言参数与纯赋值行不是脚本调用。
      [[ "$body" =~ ^[[:space:]]*(assert_contains|assert_not_contains)[[:space:]] ]] && continue
      [[ "$body" =~ $policy_assign_re ]] && continue
      # 通过变量保存的脚本路径同样必须由 bash 调用。
      if [[ "$body" =~ ^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\"[^\"]*[.]sh\"[[:space:]]*$ ]]; then
        continue
      fi
    fi
    scan="$body"
    while [[ "$scan" =~ $policy_path_re ]]; do
      match="${BASH_REMATCH[0]}"
      prefix="${scan%%"$match"*}"
      if [[ ! ( "$prefix" =~ $policy_caller_re || "$prefix" =~ $policy_checker_re ) ]]; then
        echo "${line%%:*}:$num directly executes repository script without bash: $match" >&2
        return 1
      fi
      scan="${scan#*"$match"}"
    done
  done
}

policy_check_paths workflow < <(grep -En "$policy_path_re" "$ROOT"/.github/workflows/*.yml)
policy_check_paths shell < <(grep -En "$policy_path_re" "$ROOT"/tests/*.sh "$ROOT"/scripts/*.sh)

# 持有仓库脚本路径的变量（如 SCRIPT="$ROOT/scripts/foo.sh"）同样只能经 bash 调用。
policy_var_names=()
while IFS= read -r v_line; do
  [[ "$v_line" =~ ^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\"[^\"]*[.]sh\"[[:space:]]*$ ]] || continue
  v_name="${v_line%%=*}"
  policy_var_names+=("${v_name//[[:space:]]/}")
done < <(cat "$ROOT"/tests/*.sh "$ROOT"/scripts/*.sh)
[[ "${#policy_var_names[@]}" -gt 0 ]] || { echo 'no script path variables found in tests/scripts' >&2; exit 1; }
policy_var_head_re='[$][{]?'
policy_var_tail_re='[}]?([^A-Za-z0-9_]|$)'
policy_bash_end_re='(^|[[:space:]();&`])bash[[:space:]]'
for v_name in "${policy_var_names[@]}"; do
  while IFS= read -r v_line; do
    v_rest="${v_line#*:}"
    v_body="${v_rest#*:}"
    [[ "$v_body" =~ ^[[:space:]]*# ]] && continue
    [[ "$v_body" =~ ^[[:space:]]*(assert_contains|assert_not_contains)[[:space:]] ]] && continue
    [[ "$v_body" =~ ^[[:space:]]*${v_name}= ]] && continue
    v_scan="$v_body"
    while [[ "$v_scan" =~ ${policy_var_head_re}${v_name}${policy_var_tail_re} ]]; do
      v_match="${BASH_REMATCH[0]}"
      v_prefix="${v_scan%%"$v_match"*}"
      [[ "$v_prefix" =~ $policy_bash_end_re ]] || {
        echo "${v_line%%:*} invokes script variable without bash: \$${v_name}" >&2
        exit 1
      }
      v_scan="${v_scan#*"$v_match"}"
    done
  done < <(grep -En "[$][{]?${v_name}[}]?([^A-Za-z0-9_]|$)" "$ROOT"/tests/*.sh "$ROOT"/scripts/*.sh)
done

# 仓库脚本必须以非可执行 100644 跟踪（以 Git 索引为准），确保任何推送方式都不依赖执行位。
policy_modes="$(git -C "$ROOT" ls-files --stage -- 'scripts/*.sh' 'tests/*.sh')"
[[ -n "$policy_modes" ]] || { echo 'no tracked repository scripts found' >&2; exit 1; }
policy_tracked=0
while read -r p_mode _ _ p_path; do
  [[ "$p_mode" == "100644" ]] || { echo "repository script must be tracked non-executable: $p_path" >&2; exit 1; }
  policy_tracked=$((policy_tracked + 1))
done <<< "$policy_modes"
policy_on_disk="$(find "$ROOT/scripts" "$ROOT/tests" -maxdepth 1 -type f -name '*.sh' -print | wc -l)"
[[ "$policy_tracked" -eq "$policy_on_disk" ]] || {
  echo "tracked scripts ($policy_tracked) differ from scripts on disk ($policy_on_disk)" >&2
  exit 1
}

# README 只说明本项目提供的镜像与基本使用方法，不描述上游功能。
assert_contains "$README" 'ghcr.io/cary17/sing-box:latest'
assert_contains "$README" 'ghcr.io/cary17/sing-box:testing'
assert_contains "$README" 'docker compose up -d'
assert_contains "$README" 'docker compose pull'
assert_contains "$README" 'mkdir -p conf'
assert_not_contains "$README" '/opt/sing-box'
assert_contains "$README" 'image: ghcr.io/cary17/sing-box:v1.14.0'
assert_not_contains "$README" 'sha256:<manifest-digest>'
assert_contains "$README" 'force_build'
assert_not_contains "$README" 'eBPF'
assert_not_contains "$README" 'with_ebpf'
assert_not_contains "$README" 'CGO_ENABLED'
assert_not_contains "$README" 'CGO: disabled'
assert_not_contains "$README" '统一 TC'
assert_not_contains "$README" '上游功能'
assert_contains "$EBPF_COMPOSE" 'image: ghcr.io/cary17/sing-box:latest'
assert_not_contains "$EBPF_COMPOSE" 'image: ghcr.io/cary17/sing-box:testing'

echo 'project checks passed'
