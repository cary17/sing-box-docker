#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/select-upstream-version.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/releases.json" <<'JSON'
[
  {"tag_name":"v99.0.0-reF1nd.1\";printf${IFS}INJECTED;#","draft":false,"prerelease":false,"published_at":"2026-07-24T01:00:00Z"},
  {"tag_name":"v99.0.0-rc.1-reF1nd\";printf${IFS}INJECTED;#","draft":false,"prerelease":true,"published_at":"2026-07-24T01:00:00Z"},
  {"tag_name":"v1.14.0-alpha.50-reF1nd","draft":false,"prerelease":true,"published_at":"2026-07-22T03:15:49Z"},
  {"tag_name":"v1.14.0-beta.1-reF1nd","draft":false,"prerelease":true,"published_at":"2026-07-23T16:55:26Z"},
  {"tag_name":"v1.13.14-reF1nd.2","draft":false,"prerelease":false,"published_at":"2026-07-24T00:00:00Z"}
]
JSON

cat > "$TMP/tags.json" <<'JSON'
[
  {"name":"v1.14.0-alpha.99-reF1nd"},
  {"name":"v1.14.0-beta.1-reF1nd"},
  {"name":"v1.14.0-rc.1-reF1nd"},
  {"name":"v1.13.14-reF1nd.1"},
  {"name":"v1.13.14-reF1nd.2"}
]
JSON

TESTING="$(bash "$SCRIPT" testing "$TMP/releases.json")"
STABLE="$(bash "$SCRIPT" stable "$TMP/releases.json")"

[[ "$(jq -r '.version' <<< "$TESTING")" == 'v1.14.0-beta.1-reF1nd' ]]
[[ "$(jq -r '.docker_tag' <<< "$TESTING")" == 'v1.14.0-beta.1' ]]
[[ "$(jq -r '.version' <<< "$STABLE")" == 'v1.13.14-reF1nd.2' ]]
[[ "$(jq -r '.docker_tag' <<< "$STABLE")" == 'v1.13.14' ]]

# 同一基础版本的 reF1nd 修订号会映射到同一 Docker tag，以新修订覆盖旧镜像。
cat > "$TMP/revision-one.json" <<'JSON'
[
  {"tag_name":"v1.13.14-reF1nd.1","draft":false,"prerelease":false,"published_at":"2026-07-23T00:00:00Z"}
]
JSON
REVISION_ONE="$(bash "$SCRIPT" stable "$TMP/revision-one.json")"
[[ "$(jq -r '.docker_tag' <<< "$REVISION_ONE")" == 'v1.13.14' ]]

# Release 没有更新时，tags 回退仍需正确排序 alpha < beta < rc，并保留短 Docker tag。
EMPTY_RELEASES="$TMP/empty-releases.json"
printf '[]\n' > "$EMPTY_RELEASES"
FALLBACK_TESTING="$(bash "$SCRIPT" testing "$EMPTY_RELEASES" "$TMP/tags.json" '' '2026-07-24T08:00:00+08:00')"
FALLBACK_STABLE="$(bash "$SCRIPT" stable "$EMPTY_RELEASES" "$TMP/tags.json" '' '2026-07-24T08:00:00+08:00')"
[[ "$(jq -r '.version' <<< "$FALLBACK_TESTING")" == 'v1.14.0-rc.1-reF1nd' ]]
[[ "$(jq -r '.docker_tag' <<< "$FALLBACK_TESTING")" == 'v1.14.0-rc.1' ]]
[[ "$(jq -r '.version' <<< "$FALLBACK_STABLE")" == 'v1.13.14-reF1nd.2' ]]
[[ "$(jq -r '.docker_tag' <<< "$FALLBACK_STABLE")" == 'v1.13.14' ]]

# 已记录相同或更新版本时，脚本必须用状态 3 表示无需构建。
if bash "$SCRIPT" stable "$TMP/releases.json" "" 'v1.13.14-reF1nd.2' >/dev/null; then
  echo 'expected no-update status for identical stable version' >&2
  exit 1
else
  [[ "$?" -eq 3 ]]
fi

if bash "$SCRIPT" testing "$TMP/releases.json" "" 'v1.14.0-rc.1-reF1nd' >/dev/null; then
  echo 'expected no-update status for newer local testing version' >&2
  exit 1
else
  [[ "$?" -eq 3 ]]
fi

echo 'version selection tests passed'
