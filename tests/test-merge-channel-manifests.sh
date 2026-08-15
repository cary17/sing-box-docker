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

"$ROOT/scripts/merge-channel-manifests.sh" stable v1.2.3 ghcr.test/sing-box docker.test/sing-box latest,stable >/dev/null

grep -Fq 'ghcr.test/sing-box:stable-build-amd64' "$MOCK_LOG"
grep -Fq 'ghcr.test/sing-box:stable-build-arm-v6' "$MOCK_LOG"
grep -Fq -- '-t ghcr.test/sing-box:v1.2.3 -t ghcr.test/sing-box:latest -t ghcr.test/sing-box:stable' "$MOCK_LOG"
grep -Fx 'ghcr_digest=sha256:test' "$GITHUB_OUTPUT"
grep -Fx 'dockerhub_digest=sha256:test' "$GITHUB_OUTPUT"

echo 'manifest merge checks passed'
