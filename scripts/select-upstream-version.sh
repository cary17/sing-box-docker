#!/usr/bin/env bash
set -euo pipefail

CHANNEL="${1:?usage: select-upstream-version.sh <stable|testing> <releases-json> [tags-json] [local-version] [tag-published-at]}"
RELEASES_JSON="${2:?usage: select-upstream-version.sh <stable|testing> <releases-json> [tags-json] [local-version] [tag-published-at]}"
TAGS_JSON="${3:-}"
LOCAL_VERSION="${4:-}"
TAG_PUBLISHED_AT="${5:-2026-06-29T00:00:00+08:00}"

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

release_entry="$(
  jq -r ".[] | ${RELEASE_FILTER} | select(.tag_name | ${RELEASE_TAG_FILTER}) | [.tag_name, (.published_at // .created_at)] | @tsv" "$RELEASES_JSON" |
    while IFS=$'\t' read -r tag published_at; do
      [[ -n "$tag" ]] || continue
      printf '%s\t%s\t%s\n' "$(version_key "$tag")" "$(beijing_time "$published_at")" "$tag"
    done |
    sort -t $'\t' -k1,1 -k2,2 |
    tail -n 1
)"

if [[ -n "$release_entry" ]]; then
  release_version="$(cut -f3 <<< "$release_entry")"
  release_published_at="$(cut -f2 <<< "$release_entry")"
  if [[ -z "$LOCAL_VERSION" || "$(version_key "$release_version")" > "$(version_key "$LOCAL_VERSION")" ]]; then
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

best_key=""
best_version=""

while IFS= read -r tag; do
  [[ -n "$tag" ]] || continue
  key="$(version_key "$tag")"
  if [[ -z "$best_key" || "$key" > "$best_key" ]]; then
    best_key="$key"
    best_version="$tag"
  fi
done < <(jq -r ".[] | .name | select(${TAG_FILTER})" "$TAGS_JSON")

if [[ -z "$best_version" ]]; then
  echo "no upstream ${CHANNEL} version found" >&2
  exit 1
fi

version="$best_version"
published_at="$TAG_PUBLISHED_AT"
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
