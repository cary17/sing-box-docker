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
  if [[ "$4" == --dry-run ]]; then
    [[ "$failure" != preview ]] || exit 1
    printf '%s\n' "$MERGED_MANIFEST"
    exit 0
  fi
  echo 'mock create output must not contaminate digest'
  if [[ "$5" == *@sha256:* ]]; then
    [[ "$5" == *@"$MANIFEST_DIGEST" ]] || exit 1
    [[ "$failure" != stage ]]
  else
    [[ "$failure" != publish ]]
  fi
  exit "$?"
fi
if [[ "$1" == run ]]; then
  [[ "$failure" != run ]] || exit 1
  version=1.2.3
  [[ "$failure" != version ]] || version=0.0.0
  printf 'sing-box version %s\nTags: with_quic,with_musl\nCGO: enabled\n' "$version"
  exit 0
fi
if [[ "$*" == *"imagetools inspect"* ]]; then
  [[ "$4" == *@"$MANIFEST_DIGEST" ]] || exit 1
  [[ "$failure" != inspect ]] || exit 1
  if [[ "$failure" == json ]]; then echo '{'; exit 0; fi
  jq --arg failure "$failure" --arg digest "$MANIFEST_DIGEST" \
    --arg arm64_variant "${MOCK_ARM64_VARIANT:-}" '
    .digest = $digest
    | if $failure == "platform" then .manifests |= .[:1] else . end
    | if $failure == "digest" then .digest = "sha256:invalid" else . end
    | if $failure == "mismatch" then .digest = ("sha256:" + ("0" * 64)) else . end
    | if $arm64_variant != "" then .manifests |= map(if .platform.architecture == "arm64" then .platform.variant = $arm64_variant else . end) else . end
  ' <<< "$MERGED_MANIFEST"
fi
MOCK
chmod +x "$TMP/docker"

export PATH="$TMP:$PATH"
export MOCK_LOG="$TMP/docker.log"
export GITHUB_OUTPUT="$TMP/output"
export MERGED_MANIFEST='{"manifests":[
{"platform":{"os":"linux","architecture":"amd64"}},
{"platform":{"os":"linux","architecture":"arm64"}}
]}'
MANIFEST_DIGEST="sha256:$(printf '%s' "$MERGED_MANIFEST" | sha256sum | cut -d' ' -f1)"
export MANIFEST_DIGEST
GHCR_DIGEST='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
DOCKERHUB_DIGEST='sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
mkdir "$TMP/digests"
for slug in amd64 arm64; do
  printf '%s\n' "$GHCR_DIGEST" > "$TMP/digests/ghcr-$slug"
  printf '%s\n' "$DOCKERHUB_DIGEST" > "$TMP/digests/dockerhub-$slug"
done

# buildx may report arm64 as linux/arm64/v8; validate it on the success path.
export MOCK_ARM64_VARIANT=v8
bash "$ROOT/scripts/merge-channel-manifests.sh" stable v1.2.3 ghcr.test/sing-box docker.test/sing-box latest,stable "$TMP/digests" 1.2.3 >/dev/null
unset MOCK_ARM64_VARIANT

grep -Fq "ghcr.test/sing-box@$GHCR_DIGEST" "$MOCK_LOG"
grep -Fq "docker.test/sing-box@$DOCKERHUB_DIGEST" "$MOCK_LOG"
grep -Fq -- '-t ghcr.test/sing-box:v1.2.3 -t ghcr.test/sing-box:latest -t ghcr.test/sing-box:stable' "$MOCK_LOG"
grep -Fx "ghcr_digest=$MANIFEST_DIGEST" "$GITHUB_OUTPUT"
grep -Fx "dockerhub_digest=$MANIFEST_DIGEST" "$GITHUB_OUTPUT"
# Staging uses only digests; both images must pass before any public tag changes.
awk '
  /:build-/ { exit 1 }
  /^run / { checked++; if ($0 !~ /@sha256:/) exit 1 }
  /imagetools create --dry-run/ { previewed++; next }
  /imagetools create/ {
    if ($5 ~ /@sha256:/) staged++
    else { if (checked != 2) exit 1; published++ }
  }
  END { if (previewed != 2 || staged != 2 || checked != 2 || published != 2) exit 1 }
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

# Explicit-version builds publish only the version tag, without channel aliases.
for channel in stable testing; do
  : > "$MOCK_LOG"
  bash "$ROOT/scripts/merge-channel-manifests.sh" "$channel" v1.2.3 ghcr.test/sing-box docker.test/sing-box "" "$TMP/digests" 1.2.3 >/dev/null
  grep -Fq -- '-t ghcr.test/sing-box:v1.2.3 ghcr.test/sing-box@' "$MOCK_LOG"
  grep -Fq -- '-t docker.test/sing-box:v1.2.3 docker.test/sing-box@' "$MOCK_LOG"
  if grep -Eq -- '-t [^ ]+:(latest|stable|testing)( |$)' "$MOCK_LOG"; then
    echo 'explicit-version build changed a floating tag' >&2; exit 1
  fi
done

# Validation failures must not publish either registry; publication failures must
# still fail the step and leave version-record outputs unwritten.
for failure in preview stage inspect json platform digest mismatch run version publish; do
  : > "$MOCK_LOG"
  : > "$GITHUB_OUTPUT"
  export MOCK_FAILURE="$failure"
  if bash "$ROOT/scripts/merge-channel-manifests.sh" stable v1.2.3 ghcr.test/sing-box docker.test/sing-box latest,stable "$TMP/digests" 1.2.3 >"$TMP/stdout" 2>"$TMP/stderr"; then
    echo "$failure failure unexpectedly passed" >&2
    exit 1
  fi
  [[ ! -s "$GITHUB_OUTPUT" ]]
  if [[ "$failure" != publish ]] && grep 'imagetools create -t' "$MOCK_LOG" | grep -qvE ' -t [^ ]+@sha256:[0-9a-f]+ '; then
    echo "public tag changed before $failure validation" >&2
    exit 1
  fi
done
unset MOCK_FAILURE

rm "$TMP/digests/ghcr-arm64"
if bash "$ROOT/scripts/merge-channel-manifests.sh" stable v1.2.3 ghcr.test/sing-box docker.test/sing-box latest,stable "$TMP/digests" 1.2.3 >/dev/null 2>&1; then
  echo 'missing digest unexpectedly passed' >&2
  exit 1
fi

echo 'manifest merge checks passed'
