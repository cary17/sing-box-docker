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
DIGEST='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
mkdir "$TMP/digests"
for slug in amd64 arm64 386 arm-v7 arm-v6; do
  printf '%s\n' "$DIGEST" > "$TMP/digests/$slug"
done

"$ROOT/scripts/merge-channel-manifests.sh" stable v1.2.3 ghcr.test/sing-box docker.test/sing-box latest,stable "$TMP/digests" >/dev/null

grep -Fq "ghcr.test/sing-box@$DIGEST" "$MOCK_LOG"
grep -Fq -- '-t ghcr.test/sing-box:v1.2.3 -t ghcr.test/sing-box:latest -t ghcr.test/sing-box:stable' "$MOCK_LOG"
grep -Fx 'ghcr_digest=sha256:test' "$GITHUB_OUTPUT"
grep -Fx 'dockerhub_digest=sha256:test' "$GITHUB_OUTPUT"

rm "$TMP/digests/arm-v6"
if "$ROOT/scripts/merge-channel-manifests.sh" stable v1.2.3 ghcr.test/sing-box docker.test/sing-box latest,stable "$TMP/digests" >/dev/null 2>&1; then
  echo 'missing digest unexpectedly passed' >&2
  exit 1
fi

echo 'manifest merge checks passed'
