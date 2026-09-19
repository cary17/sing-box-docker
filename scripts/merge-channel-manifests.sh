#!/usr/bin/env bash
set -euo pipefail

CHANNEL="${1:?usage: merge-channel-manifests.sh <channel> <version-tag> <ghcr-image> <dockerhub-image> <aliases> <digest-dir> <source-version>}"
VERSION_TAG="${2:?missing version tag}"
GHCR_IMAGE="${3:?missing GHCR image}"
DOCKERHUB_IMAGE="${4:?missing Docker Hub image}"
ALIASES="${5:?missing comma-separated aliases}"
DIGEST_DIR="${6:?missing digest directory}"
SOURCE_VERSION="${7:?missing source version}"
# ponytail: per-run staging tags remain; add registry retention if tag counts grow costly.
STAGING_TAG="build-${GITHUB_RUN_ID:?}-${GITHUB_RUN_ATTEMPT:?}-${CHANNEL}"
[[ "$CHANNEL" == stable || "$CHANNEL" == testing ]] || { echo "invalid channel: $CHANNEL" >&2; exit 1; }

SLUGS=(amd64 arm64 386 arm-v7 arm-v6)
EXPECTED_PLATFORMS=(linux/amd64 linux/arm64 linux/386 linux/arm/v7 linux/arm/v6)

merge_registry() {
  local image="$1"
  local prefix="$2"
  local -a sources=()
  local alias digest manifest actual platform

  for alias in "${SLUGS[@]}"; do
    [[ -f "$DIGEST_DIR/$prefix-$alias" ]] || { echo "missing digest: $prefix-$alias" >&2; exit 1; }
    digest="$(<"$DIGEST_DIR/$prefix-$alias")"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "invalid digest: $prefix-$alias" >&2; exit 1; }
    sources+=("${image}@${digest}")
  done
  # Explicit returns also work inside command substitutions, where errexit is cleared.
  docker buildx imagetools create -t "${image}:${STAGING_TAG}" "${sources[@]}" >&2 || return 1
  manifest="$(docker buildx imagetools inspect "${image}:${STAGING_TAG}" --format '{{json .Manifest}}')" || return 1
  actual="$(jq -r '
    .manifests[]
    | select(.platform.os != "unknown")
    | (.platform.os + "/" + .platform.architecture
       + (if .platform.variant then "/" + .platform.variant else "" end))
  ' <<< "$manifest")" || return 1
  for platform in "${EXPECTED_PLATFORMS[@]}"; do
    grep -qx "$platform" <<< "$actual" || { echo "missing platform: $image $platform" >&2; return 1; }
  done
  digest="$(jq -er '.digest' <<< "$manifest")" || return 1
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "invalid manifest digest: $image" >&2; return 1; }
  printf '%s\n' "$digest"
}

verify_image() {
  local output
  output="$(docker run --rm --platform linux/amd64 "$1@$2" version)" || return 1
  printf '%s\n' "$output"
  grep -Fx "sing-box version $SOURCE_VERSION" <<< "$output" || return 1
  sed -n 's/^Tags: //p' <<< "$output" | tr ',' '\n' | grep -Fx 'with_ebpf' || return 1
  grep -Fx 'CGO: disabled' <<< "$output" || return 1
}

publish_registry() {
  local image="$1" digest="$2" alias
  local -a tags=(-t "${image}:${VERSION_TAG}") alias_list=()
  IFS=',' read -ra alias_list <<< "$ALIASES"
  for alias in "${alias_list[@]}"; do
    tags+=(-t "${image}:${alias}")
  done
  docker buildx imagetools create "${tags[@]}" "$image@$digest"
}

GHCR_DIGEST="$(merge_registry "$GHCR_IMAGE" ghcr)"
DOCKERHUB_DIGEST="$(merge_registry "$DOCKERHUB_IMAGE" dockerhub)"
verify_image "$GHCR_IMAGE" "$GHCR_DIGEST"
verify_image "$DOCKERHUB_IMAGE" "$DOCKERHUB_DIGEST"
# Both registries must pass validation before any public tag changes.
publish_registry "$GHCR_IMAGE" "$GHCR_DIGEST"
publish_registry "$DOCKERHUB_IMAGE" "$DOCKERHUB_DIGEST"
printf 'ghcr_digest=%s\ndockerhub_digest=%s\n' "$GHCR_DIGEST" "$DOCKERHUB_DIGEST" >> "$GITHUB_OUTPUT"
printf 'GHCR digest: %s\nDocker Hub digest: %s\n' "$GHCR_DIGEST" "$DOCKERHUB_DIGEST"
