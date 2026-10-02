#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_LOG"
failure=""
if [[ "$*" == *docker.test/* ]]; then failure="${MOCK_FAILURE:-}"; fi
if [[ "$*" == *'imagetools create'* ]]; then
  echo 'mock create output must not contaminate digest'
  if [[ "$*" == *':build-'* ]]; then
    [[ "$failure" != stage ]]
  else
    [[ "$failure" != publish ]]
  fi
  exit "$?"
fi
if [[ "$1" == run ]]; then
  [[ "$failure" != run ]] || exit 1
  version=1.2.3 tags=with_ebpf cgo=disabled
  [[ "$failure" != version ]] || version=0.0.0
  [[ "$failure" != tags ]] || tags=with_quic
  [[ "$failure" != cgo ]] || cgo=enabled
  printf 'sing-box version %s\nTags: %s\nCGO: %s\n' "$version" "$tags" "$cgo"
  exit 0
fi
if [[ "$*" == *"imagetools inspect"* ]]; then
  [[ "$failure" != inspect ]] || exit 1
  if [[ "$failure" == json ]]; then echo '{'; exit 0; fi
  # 清单内容完全由环境变量控制：MOCK_ARM64_VARIANT 设定 arm64 variant，
  # MOCK_DROP_ARCH 删除某个 architecture。
  jq --arg failure "$failure" --arg digest "$MANIFEST_DIGEST" \
    --arg arm64_variant "${MOCK_ARM64_VARIANT:-}" \
    --arg drop_arch "${MOCK_DROP_ARCH:-}" '
    .digest = $digest
    | if $failure == "platform" then .manifests |= .[:1] else . end
    | if $failure == "digest" then .digest = "sha256:invalid" else . end
    | if $drop_arch != "" then .manifests |= map(select(.platform.architecture != $drop_arch)) else . end
    | if $arm64_variant != "" then .manifests |= map(if .platform.architecture == "arm64" then .platform.variant = $arm64_variant else . end) else . end
  ' <<'JSON'
{"manifests":[
{"platform":{"os":"linux","architecture":"amd64"}},
{"platform":{"os":"linux","architecture":"arm64"}},
{"platform":{"os":"linux","architecture":"386"}},
{"platform":{"os":"linux","architecture":"arm","variant":"v7"}},
{"platform":{"os":"linux","architecture":"arm","variant":"v6"}}
]}
JSON
fi
MOCK
chmod +x "$TMP/docker"

export PATH="$TMP:$PATH"
export MOCK_LOG="$TMP/docker.log"
export GITHUB_OUTPUT="$TMP/output"
export GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=1
export MANIFEST_DIGEST='sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
GHCR_DIGEST='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
DOCKERHUB_DIGEST='sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
mkdir "$TMP/digests"
for slug in amd64 arm64 386 arm-v7 arm-v6; do
  printf '%s\n' "$GHCR_DIGEST" > "$TMP/digests/ghcr-$slug"
  printf '%s\n' "$DOCKERHUB_DIGEST" > "$TMP/digests/dockerhub-$slug"
done

bash "$ROOT/scripts/merge-channel-manifests.sh" stable v1.2.3 ghcr.test/sing-box docker.test/sing-box latest,stable "$TMP/digests" 1.2.3 >/dev/null

grep -Fq "ghcr.test/sing-box@$GHCR_DIGEST" "$MOCK_LOG"
grep -Fq "docker.test/sing-box@$DOCKERHUB_DIGEST" "$MOCK_LOG"
grep -Fq -- '-t ghcr.test/sing-box:v1.2.3 -t ghcr.test/sing-box:latest -t ghcr.test/sing-box:stable' "$MOCK_LOG"
grep -Fx "ghcr_digest=$MANIFEST_DIGEST" "$GITHUB_OUTPUT"
grep -Fx "dockerhub_digest=$MANIFEST_DIGEST" "$GITHUB_OUTPUT"
# Both immutable image references must be checked before the first public tag.
awk '
  /^run / { checked++; if ($0 !~ /@sha256:/) exit 1 }
  /imagetools create/ && !/:build-/ { if (checked != 2) exit 1; published++ }
  END { if (checked != 2 || published != 2) exit 1 }
' "$MOCK_LOG"

# 修订版只发布完整精确标签和渠道浮动标签，不得额外发布基础版本标签。
: > "$MOCK_LOG"
bash "$ROOT/scripts/merge-channel-manifests.sh" stable v1.2.3-reF1nd.1 ghcr.test/sing-box docker.test/sing-box latest,stable "$TMP/digests" 1.2.3 >/dev/null
grep -Fq -- '-t ghcr.test/sing-box:v1.2.3-reF1nd.1 -t ghcr.test/sing-box:latest -t ghcr.test/sing-box:stable' "$MOCK_LOG"
if grep -Fq -- '-t ghcr.test/sing-box:v1.2.3 ' "$MOCK_LOG"; then
  echo 'revision release unexpectedly published base version tag' >&2
  exit 1
fi

# Testing 修订版使用相同策略，只保留精确标签与 testing 浮动标签。
: > "$MOCK_LOG"
bash "$ROOT/scripts/merge-channel-manifests.sh" testing v1.2.3-rc.4-reF1nd.2 ghcr.test/sing-box docker.test/sing-box testing "$TMP/digests" 1.2.3 >/dev/null
grep -Fq -- '-t ghcr.test/sing-box:v1.2.3-rc.4-reF1nd.2 -t ghcr.test/sing-box:testing' "$MOCK_LOG"
if grep -Fq -- '-t ghcr.test/sing-box:v1.2.3-rc.4 ' "$MOCK_LOG"; then
  echo 'testing revision unexpectedly published base prerelease tag' >&2
  exit 1
fi

# linux/arm64/v8 是 docker buildx 报告的等价 arm64 表示，正规化后必须通过校验并正常发布。
: > "$MOCK_LOG"
: > "$GITHUB_OUTPUT"
export MOCK_ARM64_VARIANT=v8
bash "$ROOT/scripts/merge-channel-manifests.sh" stable v1.2.3 ghcr.test/sing-box docker.test/sing-box latest,stable "$TMP/digests" 1.2.3 >/dev/null
grep -Fq -- '-t ghcr.test/sing-box:v1.2.3 -t ghcr.test/sing-box:latest -t ghcr.test/sing-box:stable' "$MOCK_LOG"
grep -Fq -- '-t docker.test/sing-box:v1.2.3 -t docker.test/sing-box:latest -t docker.test/sing-box:stable' "$MOCK_LOG"
grep -Fx "ghcr_digest=$MANIFEST_DIGEST" "$GITHUB_OUTPUT"
grep -Fx "dockerhub_digest=$MANIFEST_DIGEST" "$GITHUB_OUTPUT"
unset MOCK_ARM64_VARIANT

# 缺失架构必须在发布任何公共标签前失败，公共标签保持不变。
: > "$MOCK_LOG"
: > "$GITHUB_OUTPUT"
export MOCK_DROP_ARCH=arm64
if bash "$ROOT/scripts/merge-channel-manifests.sh" stable v1.2.3 ghcr.test/sing-box docker.test/sing-box latest,stable "$TMP/digests" 1.2.3 >"$TMP/stdout" 2>"$TMP/stderr"; then
  echo 'missing architecture unexpectedly passed' >&2
  exit 1
fi
grep -Fq 'missing platform: ghcr.test/sing-box linux/arm64' "$TMP/stderr"
[[ ! -s "$GITHUB_OUTPUT" ]]
if grep -Fq -- '-t ghcr.test/sing-box:v1.2.3' "$MOCK_LOG" || grep -Fq -- '-t docker.test/sing-box:v1.2.3' "$MOCK_LOG"; then
  echo 'missing architecture published a public tag' >&2
  exit 1
fi
if grep 'imagetools create' "$MOCK_LOG" | grep -qv ':build-'; then
  echo 'missing architecture changed a public tag' >&2
  exit 1
fi
unset MOCK_DROP_ARCH

# Validation failures must not publish either registry; publication failures must
# still fail the step and leave version-record outputs unwritten.
for failure in stage inspect json platform digest run version tags cgo publish; do
  : > "$MOCK_LOG"
  : > "$GITHUB_OUTPUT"
  export MOCK_FAILURE="$failure"
  if bash "$ROOT/scripts/merge-channel-manifests.sh" stable v1.2.3 ghcr.test/sing-box docker.test/sing-box latest,stable "$TMP/digests" 1.2.3 >"$TMP/stdout" 2>"$TMP/stderr"; then
    echo "$failure failure unexpectedly passed" >&2
    exit 1
  fi
  [[ ! -s "$GITHUB_OUTPUT" ]]
  if [[ "$failure" != publish ]] && grep 'imagetools create' "$MOCK_LOG" | grep -qv ':build-'; then
    echo "public tag changed before $failure validation" >&2
    exit 1
  fi
done
unset MOCK_FAILURE

rm "$TMP/digests/ghcr-arm-v6"
if bash "$ROOT/scripts/merge-channel-manifests.sh" stable v1.2.3 ghcr.test/sing-box docker.test/sing-box latest,stable "$TMP/digests" 1.2.3 >/dev/null 2>&1; then
  echo 'missing digest unexpectedly passed' >&2
  exit 1
fi

echo 'manifest merge checks passed'
