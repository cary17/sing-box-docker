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
[[ "$(jq -r '.docker_tag' <<< "$STABLE")" == 'v1.13.14-reF1nd.2' ]]

# 只有带数字修订号的 reF1nd 版本使用完整 Docker tag；不带修订号时保持短 tag。
cat > "$TMP/revision-one.json" <<'JSON'
[
  {"tag_name":"v1.13.14-reF1nd.1","draft":false,"prerelease":false,"published_at":"2026-07-23T00:00:00Z"}
]
JSON
REVISION_ONE="$(bash "$SCRIPT" stable "$TMP/revision-one.json")"
[[ "$(jq -r '.docker_tag' <<< "$REVISION_ONE")" == 'v1.13.14-reF1nd.1' ]]

cat > "$TMP/no-revision.json" <<'JSON'
[
  {"tag_name":"v1.13.14-reF1nd","draft":false,"prerelease":false,"published_at":"2026-07-22T00:00:00Z"}
]
JSON
NO_REVISION="$(bash "$SCRIPT" stable "$TMP/no-revision.json")"
[[ "$(jq -r '.docker_tag' <<< "$NO_REVISION")" == 'v1.13.14' ]]

cat > "$TMP/testing-revision.json" <<'JSON'
[
  {"tag_name":"v1.14.0-rc.4-reF1nd.2","draft":false,"prerelease":true,"published_at":"2026-07-24T00:00:00Z"}
]
JSON
TESTING_REVISION="$(bash "$SCRIPT" testing "$TMP/testing-revision.json")"
[[ "$(jq -r '.docker_tag' <<< "$TESTING_REVISION")" == 'v1.14.0-rc.4-reF1nd.2' ]]

# Release 没有更新时，tags 回退仍需正确排序 alpha < beta < rc，并保留短 Docker tag。
EMPTY_RELEASES="$TMP/empty-releases.json"
printf '[]\n' > "$EMPTY_RELEASES"
FALLBACK_TESTING="$(bash "$SCRIPT" testing "$EMPTY_RELEASES" "$TMP/tags.json" '' '2026-07-24T08:00:00+08:00')"
FALLBACK_STABLE="$(bash "$SCRIPT" stable "$EMPTY_RELEASES" "$TMP/tags.json" '' '2026-07-24T08:00:00+08:00')"
[[ "$(jq -r '.version' <<< "$FALLBACK_TESTING")" == 'v1.14.0-rc.1-reF1nd' ]]
[[ "$(jq -r '.docker_tag' <<< "$FALLBACK_TESTING")" == 'v1.14.0-rc.1' ]]
[[ "$(jq -r '.version' <<< "$FALLBACK_STABLE")" == 'v1.13.14-reF1nd.2' ]]
[[ "$(jq -r '.docker_tag' <<< "$FALLBACK_STABLE")" == 'v1.13.14-reF1nd.2' ]]

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

# Failures must not become a successful selection or the tags-fetch status 3.
expect_failure() {
  local status=0
  bash "$SCRIPT" "$@" > "$TMP/output" 2> "$TMP/error" || status=$?
  [[ "$status" -ne 0 && "$status" -ne 3 ]]
  [[ ! -s "$TMP/output" && -s "$TMP/error" ]]
}

jq '.[0].published_at = "invalid-date"' "$TMP/no-revision.json" > "$TMP/bad-date.json"
expect_failure stable "$TMP/bad-date.json" "$TMP/tags.json"
jq '.[0].published_at = null | .[0].created_at = "2026-07-22T00:00:00Z"' \
  "$TMP/no-revision.json" > "$TMP/created-at.json"
CREATED_AT="$(bash "$SCRIPT" stable "$TMP/created-at.json")"
[[ "$(jq -r '.published_at' <<< "$CREATED_AT")" == '2026-07-22T08:00:00+08:00' ]]

jq '. + [{tag_name: "v99.0.0-reF1nd", draft: true, prerelease: false,
  published_at: null, created_at: null}]' "$TMP/no-revision.json" > "$TMP/draft.json"
DRAFT="$(bash "$SCRIPT" stable "$TMP/draft.json")"
[[ "$(jq -r '.version' <<< "$DRAFT")" == 'v1.13.14-reF1nd' ]]

# A valid JSON prefix must not hide trailing garbage or a second document.
for tail in broken '[]' '{}'; do
  printf '%s\n%s\n' "$(< "$TMP/tags.json")" "$tail" > "$TMP/bad-tags.json"
  expect_failure stable "$EMPTY_RELEASES" "$TMP/bad-tags.json"
  printf '%s\n%s\n' "$(< "$TMP/no-revision.json")" "$tail" > "$TMP/bad-releases.json"
  expect_failure stable "$TMP/bad-releases.json" "$TMP/tags.json"
done

# Validate the API envelope and record types even when no record matches.
for json in '' null '{}' '"text"' '[null]' '[[]]' '[1]' '[{}]' \
  '[{"name":null}]' '[{"name":1}]' '[{"name":false}]'; do
  printf '%s\n' "$json" > "$TMP/bad-tags.json"
  expect_failure stable "$EMPTY_RELEASES" "$TMP/bad-tags.json"
done
for json in '' null '{}' '"text"' '[null]' '[[]]' '[1]' '[{}]'; do
  printf '%s\n' "$json" > "$TMP/bad-releases.json"
  expect_failure stable "$TMP/bad-releases.json" "$TMP/tags.json"
done
for change in '.tag_name = null' '.tag_name = 1' '.draft = "false"' \
  'del(.draft)' '.prerelease = null' '.published_at = 1' \
  '.published_at = false' '.published_at = ""' '.published_at = null' \
  '.created_at = []'; do
  jq ".[0] |= ($change)" "$TMP/no-revision.json" > "$TMP/bad-releases.json"
  expect_failure stable "$TMP/bad-releases.json" "$TMP/tags.json"
done

# Invalid local records must fail before either release selection or tags fallback.
for version in garbage v1.2-reF1nd v1.2.3-reF1nd.bad v1.2.3.4-reF1nd \
  v1.2.3-rc.bad-reF1nd vV1.2.3-reF1nd; do
  expect_failure stable "$TMP/releases.json" "$TMP/tags.json" "$version"
  expect_failure stable "$EMPTY_RELEASES" "$TMP/tags.json" "$version"
done

# A newer release wins even over newer tags (or an unusable tags file).
PREFERRED="$(bash "$SCRIPT" stable "$TMP/releases.json" "$TMP/bad-tags.json" 'v1.0.0-reF1nd')"
[[ "$(jq -r '.source' <<< "$PREFERRED")" == release ]]
FALLBACK="$(bash "$SCRIPT" stable "$TMP/releases.json" "$TMP/tags.json" 'v1.13.14-reF1nd.2')"
[[ "$(jq -r '.source' <<< "$FALLBACK")" == tag ]]
expect_failure stable "$EMPTY_RELEASES" "$EMPTY_RELEASES"
expect_failure stable "$EMPTY_RELEASES" "$TMP/tags.json" '' invalid-date
TAG_TIME="$(bash "$SCRIPT" stable "$EMPTY_RELEASES" "$TMP/tags.json" '' '2026-07-24T00:00:00Z')"
[[ "$(jq -r '.published_at' <<< "$TAG_TIME")" == '2026-07-24T08:00:00+08:00' ]]
BEFORE="$(date +%s)"
TAG_NOW="$(bash "$SCRIPT" stable "$EMPTY_RELEASES" "$TMP/tags.json")"
TAG_EPOCH="$(date -d "$(jq -r '.published_at' <<< "$TAG_NOW")" +%s)"
AFTER="$(date +%s)"
[[ "$TAG_EPOCH" -ge "$BEFORE" && "$TAG_EPOCH" -le "$AFTER" ]]

# Numeric components are decimal strings, including leading zeros and huge values.
# shellcheck source=scripts/version-key.sh
source "$ROOT/scripts/version-key.sh"
[[ "$(version_key v1.08.0-reF1nd)" == "$(version_key V01.8.000-reF1nd.00)" ]]
[[ "$(version_key v1.2.3-RC.08-reF1nd.09)" == "$(version_key 1.2.3-rc.8-reF1nd.9)" ]]
[[ "$(version_key v1.0.0-alpha.999999999999999999999-reF1nd)" < "$(version_key v1.0.0-beta.0-reF1nd)" ]]
[[ "$(version_key v1.0.0-rc.999999999999999999999-reF1nd)" < "$(version_key v1.0.0-reF1nd)" ]]
if version_key 'v1.2.3-reF1nd.bad' > "$TMP/output" 2> "$TMP/error"; then
  echo 'expected invalid version failure' >&2
  exit 1
fi
[[ ! -s "$TMP/output" ]]

while read -r channel older newer; do
  [[ "$(version_key "$newer")" > "$(version_key "$older")" ]]
  jq -n --arg older "$older" --arg newer "$newer" --arg channel "$channel" '
    [$newer, $older] | map({tag_name: ., draft: false,
      prerelease: ($channel == "testing"), published_at: "2026-07-22T00:00:00Z"})
  ' > "$TMP/numeric-releases.json"
  jq 'map({name: .tag_name})' "$TMP/numeric-releases.json" > "$TMP/numeric-tags.json"
  SELECTED="$(bash "$SCRIPT" "$channel" "$TMP/numeric-releases.json" '' "$older")"
  [[ "$(jq -r '.version' <<< "$SELECTED")" == "$newer" ]]
  SELECTED="$(bash "$SCRIPT" "$channel" "$EMPTY_RELEASES" "$TMP/numeric-tags.json")"
  [[ "$(jq -r '.version' <<< "$SELECTED")" == "$newer" ]]
done <<'VERSIONS'
stable v1.07.0-reF1nd v1.08.0-reF1nd
stable v99999999.0.0-reF1nd v100000000.0.0-reF1nd
stable v1.99999999.0-reF1nd v1.100000000.0-reF1nd
stable v1.0.99999999-reF1nd v1.0.100000000-reF1nd
stable v1.0.0-reF1nd.99999999 v1.0.0-reF1nd.100000000
 testing v1.0.0-rc.99999999-reF1nd v1.0.0-rc.100000000-reF1nd
stable v999999999999999999999999999999.0.0-reF1nd v1000000000000000000000000000000.0.0-reF1nd
stable v1.0.0-reF1nd.999999999999999999999999999999 v1.0.0-reF1nd.1000000000000000000000000000000
testing v1.0.0-rc.999999999999999999999999999999-reF1nd v1.0.0-rc.1000000000000000000000000000000-reF1nd
VERSIONS

if bash "$SCRIPT" stable "$TMP/no-revision.json" '' 'V01.013.014-reF1nd.00' > "$TMP/output"; then
  echo 'expected no-update status for numerically identical local version' >&2
  exit 1
else
  [[ "$?" -eq 3 && ! -s "$TMP/output" ]]
fi

echo 'version selection tests passed'
