#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/build.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Execute the actual workflow fetch commands after the upstream branch advances.
git init -q "$TMP/upstream"
git -C "$TMP/upstream" -c user.name=Test -c user.email=test@example.invalid commit -qm initial --allow-empty
PINNED="$(git -C "$TMP/upstream" rev-parse HEAD)"
git -C "$TMP/upstream" tag v1.2.3
git -C "$TMP/upstream" -c user.name=Test -c user.email=test@example.invalid commit -qm advanced --allow-empty
for channel in stable testing; do
  commands="$(awk -v job="build_${channel}:" '
    $0 == "  " job { inside = 1 }
    inside && /if git init src/ { capture = 1 }
    capture { print }
    capture && /checkout --detach FETCH_HEAD/ { exit }
  ' "$WORKFLOW")"
  [[ -n "$commands" ]]
  # Replace GitHub expressions only; execute the production commands unchanged.
  # shellcheck disable=SC2016
  commands="${commands//'${{ env.UPSTREAM_REPO }}'/"$TMP/upstream"}"
  expression="\${{ needs.prepare_${channel}.outputs.source_commit }}"
  commands="${commands//"$expression"/"$PINNED"}"
  mkdir "$TMP/$channel"
  (cd "$TMP/$channel" && bash -eu -c "$commands exit 0; else exit 1; fi") >"$TMP/fetch.log" 2>&1 || {
    cat "$TMP/fetch.log" >&2
    exit 1
  }
  [[ "$(git -C "$TMP/$channel/src" rev-parse HEAD)" == "$PINNED" ]]
  [[ "$(git -C "$TMP/$channel/src" describe --tags)" == v1.2.3 ]]
done

# Run the complete prepare source guard: helper failure modes plus the exact
# EXPECTED_VERSION check (one leading v/V stripped on both sides, revision and
# prerelease suffixes kept verbatim).
for channel in stable testing; do
  guard="$(awk -v job="prepare_${channel}:" '
    $0 == "  " job { inside = 1 }
    inside && /if ! SOURCE_VERSION=/ { capture = 1 }
    capture && /^      - name:/ { exit }
    capture { print }
  ' "$WORKFLOW")"
  [[ -n "$guard" ]]
  printf 'FROM scratch\n' > "$TMP/$channel/src/Dockerfile"
  export GITHUB_OUTPUT="$TMP/$channel/source-output"
  # 名称|帮助器输出（- 表示帮助器失败）|期望版本|期望退出码
  cases=(
    'match|1.2.3-reF1nd.1|1.2.3-reF1nd.1|0'
    'v_prefix|v1.2.3-reF1nd.1|1.2.3-reF1nd.1|0'
    'upper_v_prefix|V1.2.3-reF1nd.1|v1.2.3-reF1nd.1|0'
    'prerelease|1.2.3-rc.4-reF1nd.2|1.2.3-rc.4-reF1nd.2|0'
    'mismatch|1.2.3|1.2.4|1'
    'mismatch_revision|1.2.3-reF1nd.1|1.2.3-reF1nd.2|1'
    'empty||1.2.3|1'
    'unknown|unknown|1.2.3|1'
    'helper_failed|-|1.2.3|1'
  )
  for entry in "${cases[@]}"; do
    IFS='|' read -r name helper expected want <<< "$entry"
    : > "$GITHUB_OUTPUT"
    export EXPECTED_VERSION="$expected"
    export CASE_HELPER="$helper"
    if (
      cd "$TMP/$channel"
      # Invoked by the extracted workflow in a child shell.
      # shellcheck disable=SC2317
      go() {
        if [[ "$CASE_HELPER" == '-' ]]; then
          return 1
        elif [[ "$CASE_HELPER" == 'unknown' ]]; then
          echo unknown
        elif [[ -n "$CASE_HELPER" ]]; then
          printf '%s\n' "$CASE_HELPER"
        fi
      }
      export -f go
      bash -eu -c "$guard"
    ) >"$TMP/$channel/source.log" 2>&1; then
      status=0
    else
      status=$?
    fi
    if [[ "$status" -ne "$want" ]]; then
      echo "prepare_${channel} ${name}: expected exit ${want}, got ${status}" >&2
      cat "$TMP/$channel/source.log" >&2
      exit 1
    fi
    if [[ "$want" -ne 0 ]]; then
      # 校验失败必须发生在 source_commit 输出之前。
      if grep -Fq 'source_commit' "$GITHUB_OUTPUT"; then
        echo 'source_commit written before source validation' >&2
        exit 1
      fi
    fi
    case "$name" in
      mismatch*)
        # 错误信息必须同时包含期望版本与实际版本。
        grep -Fq -- "$expected" "$TMP/$channel/source.log"
        grep -Fq -- "$helper" "$TMP/$channel/source.log"
        ;;
    esac
  done
done

# Execute both production version-check guards, including helper failures.
for channel in stable testing; do
  guard="$(awk -v step="${channel}_check" '
    $0 == "        id: " step { inside = 1 }
    inside && /source scripts\/version-key.sh/ { capture = 1 }
    capture { print }
    capture && /^          fi$/ { exit }
  ' "$WORKFLOW")"
  [[ -n "$guard" ]]
  for result in valid empty_local invalid_current invalid_local; do
    CURRENT=v1.2.3-reF1nd LOCAL=v1.2.2-reF1nd
    case "$result" in
      empty_local) LOCAL="";;
      invalid_current) CURRENT=invalid;;
      invalid_local) LOCAL=invalid;;
    esac
    if (cd "$ROOT" && export CURRENT LOCAL && bash -eu -c "$guard") >/dev/null 2>&1; then
      [[ "$result" == valid || "$result" == empty_local ]]
    else
      [[ "$result" == invalid_current || "$result" == invalid_local ]]
    fi
  done
done

echo 'project checks passed'
