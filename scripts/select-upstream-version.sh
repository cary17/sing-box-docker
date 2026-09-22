#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

CHANNEL="${1:?usage: select-upstream-version.sh <stable|testing> <releases-json> [tags-json] [local-version] [tag-published-at]}"
RELEASES_JSON="${2:?usage: select-upstream-version.sh <stable|testing> <releases-json> [tags-json] [local-version] [tag-published-at]}"
TAGS_JSON="${3:-}"
LOCAL_VERSION="${4:-}"
TAG_PUBLISHED_AT="${5:-now}"

case "$CHANNEL" in
  stable)
    RELEASE_FILTER='select(.draft == false and .prerelease == false)'
    RELEASE_TAG_FILTER='test("^[vV]?[0-9]+\\.[0-9]+\\.[0-9]+-reF1nd(\\.[0-9]+)?$")'
    TAG_FILTER='test("^[vV]?[0-9]+\\.[0-9]+\\.[0-9]+-reF1nd(\\.[0-9]+)?$")'
    ;;
  testing)
    RELEASE_FILTER='select(.draft == false and .prerelease == true)'
    RELEASE_TAG_FILTER='test("^[vV]?[0-9]+\\.[0-9]+\\.[0-9]+-[A-Za-z]+\\.[0-9]+-reF1nd(\\.[0-9]+)?$")'
    TAG_FILTER='test("^[vV]?[0-9]+\\.[0-9]+\\.[0-9]+-[A-Za-z]+\\.[0-9]+-reF1nd(\\.[0-9]+)?$")'
    ;;
  *)
    echo "unsupported channel: ${CHANNEL}" >&2
    exit 2
    ;;
esac

# shellcheck source=scripts/version-key.sh
source "$(dirname "${BASH_SOURCE[0]}")/version-key.sh"

beijing_time() {
  TZ=Asia/Shanghai date -d "$1" +'%Y-%m-%dT%H:%M:%S+08:00'
}

docker_tag_for_version() {
  local version="$1"
  if [[ "$version" =~ -reF1nd\.[0-9]+$ ]]; then
    printf '%s\n' "$version"
  else
    printf '%s\n' "${version%%-reF1nd*}"
  fi
}

local_key=""
if [[ -n "$LOCAL_VERSION" ]]; then
  local_key="$(version_key "$LOCAL_VERSION")" || exit 1
fi

release_rows="$(
  jq -sr '
    if length != 1 or (.[0] | type) != "array" then error("expected one releases array")
    else .[0] end |
    if all(.[]; type == "object" and
      (.tag_name | type == "string") and
      (.draft | type == "boolean") and (.prerelease | type == "boolean") and
      (.published_at | type == "null" or type == "string") and
      (.created_at | type == "null" or type == "string"))
    then . else error("invalid release record") end |
    .[] | '"${RELEASE_FILTER}"' | select(.tag_name | '"${RELEASE_TAG_FILTER}"') |
    if ((.published_at // .created_at) | type == "string" and length > 0)
    then [.tag_name, (.published_at // .created_at)] | @tsv
    else error("missing release timestamp") end
  ' "$RELEASES_JSON"
)" || exit 1

release_entry="$(
  while IFS=$'\t' read -r tag published_at; do
    [[ -n "$tag" ]] || continue
    key="$(version_key "$tag")" || exit 1
    published_at="$(beijing_time "$published_at")" || exit 1
    printf '%s\t%s\t%s\n' "$key" "$published_at" "$tag"
  done <<< "$release_rows" |
    sort -t $'\t' -k1,1 -k2,2 |
    tail -n 1
)" || exit 1

if [[ -n "$release_entry" ]]; then
  release_version="$(cut -f3 <<< "$release_entry")"
  release_published_at="$(cut -f2 <<< "$release_entry")"
  release_key="$(cut -f1 <<< "$release_entry")"
  if [[ -z "$local_key" || "$release_key" > "$local_key" ]]; then
    version="$release_version"
    published_at="$release_published_at"
    source="release"
    docker_tag="$(docker_tag_for_version "$version")"
    jq -n \
      --arg version "$version" \
      --arg published_at "$published_at" \
      --arg docker_tag "$docker_tag" \
      --arg source "$source" \
      '{
        version: $version,
        published_at: $published_at,
        docker_tag: $docker_tag,
        source: $source
      }'
    exit 0
  fi
fi

if [[ -z "$TAGS_JSON" ]]; then
  exit 3
fi

tags="$(
  jq -sr '
    if length != 1 or (.[0] | type) != "array" then error("expected one tags array")
    else .[0] end |
    if all(.[]; type == "object" and (.name | type == "string"))
    then . else error("invalid tag record") end |
    .[] | .name | select('"${TAG_FILTER}"')
  ' "$TAGS_JSON"
)" || exit 1

best_key=""
best_version=""

while IFS= read -r tag; do
  [[ -n "$tag" ]] || continue
  key="$(version_key "$tag")" || exit 1
  if [[ -z "$best_key" || "$key" > "$best_key" ]]; then
    best_key="$key"
    best_version="$tag"
  fi
done <<< "$tags"

if [[ -z "$best_version" ]]; then
  echo "no upstream ${CHANNEL} version found" >&2
  exit 1
fi

version="$best_version"
published_at="$(beijing_time "$TAG_PUBLISHED_AT")" || exit 1
source="tag"
docker_tag="$(docker_tag_for_version "$version")"

jq -n \
  --arg version "$version" \
  --arg published_at "$published_at" \
  --arg docker_tag "$docker_tag" \
  --arg source "$source" \
  '{
    version: $version,
    published_at: $published_at,
    docker_tag: $docker_tag,
    source: $source
  }'
