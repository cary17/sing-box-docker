#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_LOG"
if [[ "$*" == *"imagetools inspect"* ]]; then
  cat <<'JSON'
{"digest":"sha256:test","manifests":[
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
GHCR_DIGEST='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
DOCKERHUB_DIGEST='sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
mkdir "$TMP/digests"
for slug in amd64 arm64 386 arm-v7 arm-v6; do
  printf '%s\n' "$GHCR_DIGEST" > "$TMP/digests/ghcr-$slug"
  printf '%s\n' "$DOCKERHUB_DIGEST" > "$TMP/digests/dockerhub-$slug"
done

"$ROOT/scripts/merge-channel-manifests.sh" stable v1.2.3 ghcr.test/sing-box docker.test/sing-box latest,stable "$TMP/digests" >/dev/null

grep -Fq "ghcr.test/sing-box@$GHCR_DIGEST" "$MOCK_LOG"
grep -Fq "docker.test/sing-box@$DOCKERHUB_DIGEST" "$MOCK_LOG"
grep -Fq -- '-t ghcr.test/sing-box:v1.2.3 -t ghcr.test/sing-box:latest -t ghcr.test/sing-box:stable' "$MOCK_LOG"
grep -Fx 'ghcr_digest=sha256:test' "$GITHUB_OUTPUT"
grep -Fx 'dockerhub_digest=sha256:test' "$GITHUB_OUTPUT"

# 修订版只发布完整精确标签和渠道浮动标签，不得额外发布基础版本标签。
: > "$MOCK_LOG"
"$ROOT/scripts/merge-channel-manifests.sh" stable v1.2.3-reF1nd.1 ghcr.test/sing-box docker.test/sing-box latest,stable "$TMP/digests" >/dev/null
grep -Fq -- '-t ghcr.test/sing-box:v1.2.3-reF1nd.1 -t ghcr.test/sing-box:latest -t ghcr.test/sing-box:stable' "$MOCK_LOG"
if grep -Fq -- '-t ghcr.test/sing-box:v1.2.3 ' "$MOCK_LOG"; then
  echo 'revision release unexpectedly published base version tag' >&2
  exit 1
fi

# Testing 修订版使用相同策略，只保留精确标签与 testing 浮动标签。
: > "$MOCK_LOG"
"$ROOT/scripts/merge-channel-manifests.sh" testing v1.2.3-rc.4-reF1nd.2 ghcr.test/sing-box docker.test/sing-box testing "$TMP/digests" >/dev/null
grep -Fq -- '-t ghcr.test/sing-box:v1.2.3-rc.4-reF1nd.2 -t ghcr.test/sing-box:testing' "$MOCK_LOG"
if grep -Fq -- '-t ghcr.test/sing-box:v1.2.3-rc.4 ' "$MOCK_LOG"; then
  echo 'testing revision unexpectedly published base prerelease tag' >&2
  exit 1
fi

rm "$TMP/digests/ghcr-arm-v6"
if "$ROOT/scripts/merge-channel-manifests.sh" stable v1.2.3 ghcr.test/sing-box docker.test/sing-box latest,stable "$TMP/digests" >/dev/null 2>&1; then
  echo 'missing digest unexpectedly passed' >&2
  exit 1
fi

echo 'manifest merge checks passed'
