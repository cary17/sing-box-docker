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

version_key() {
  local tag="${1#v}"
  tag="${tag#V}"
  local base="${tag%%-reF1nd*}"
  local suffix="${tag#*-reF1nd}"
  local version_part prerelease_part prerelease_name major minor patch prerelease_rank prerelease_number revision

  if [[ "$base" == *-* ]]; then
    version_part="${base%%-*}"
    prerelease_part="${base#*-}"
    prerelease_name="${prerelease_part%%.*}"
    case "${prerelease_name,,}" in
      alpha) prerelease_rank=1 ;;
      beta) prerelease_rank=2 ;;
      rc) prerelease_rank=3 ;;
      *) prerelease_rank=0 ;;
    esac
    prerelease_number="${prerelease_part##*.}"
    [[ "$prerelease_number" =~ ^[0-9]+$ ]] || prerelease_number=0
  else
    version_part="$base"
    prerelease_rank=99999999
    prerelease_number=99999999
  fi

  IFS=. read -r major minor patch _ <<< "$version_part"
  if [[ "$suffix" == "$tag" || -z "$suffix" ]]; then
    revision=0
  else
    revision="${suffix#.}"
    [[ "$revision" =~ ^[0-9]+$ ]] || revision=0
  fi

  printf '%08d.%08d.%08d.%08d.%08d.%08d' "${major:-0}" "${minor:-0}" "${patch:-0}" "${prerelease_rank:-0}" "${prerelease_number:-0}" "${revision:-0}"
}

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
