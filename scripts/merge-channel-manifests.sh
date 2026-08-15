#!/usr/bin/env bash
set -euo pipefail

CHANNEL="${1:?usage: merge-channel-manifests.sh <channel> <version-tag> <ghcr-image> <dockerhub-image> <aliases> <digest-dir>}"
VERSION_TAG="${2:?missing version tag}"
GHCR_IMAGE="${3:?missing GHCR image}"
DOCKERHUB_IMAGE="${4:?missing Docker Hub image}"
ALIASES="${5:?missing comma-separated aliases}"
DIGEST_DIR="${6:?missing digest directory}"
[[ "$CHANNEL" == stable || "$CHANNEL" == testing ]] || { echo "invalid channel: $CHANNEL" >&2; exit 1; }

SLUGS=(amd64 arm64 386 arm-v7 arm-v6)
EXPECTED_PLATFORMS=(linux/amd64 linux/arm64 linux/386 linux/arm/v7 linux/arm/v6)

merge_registry() {
  local image="$1"
  local prefix="$2"
  local -a sources tags
  local alias digest manifest actual platform

  for alias in "${SLUGS[@]}"; do
    [[ -f "$DIGEST_DIR/$prefix-$alias" ]] || { echo "missing digest: $prefix-$alias" >&2; exit 1; }
    digest="$(<"$DIGEST_DIR/$prefix-$alias")"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "invalid digest: $prefix-$alias" >&2; exit 1; }
    sources+=("${image}@${digest}")
  done
  tags=(-t "${image}:${VERSION_TAG}")
  IFS=',' read -ra alias_list <<< "$ALIASES"
  for alias in "${alias_list[@]}"; do
    tags+=(-t "${image}:${alias}")
  done

  docker buildx imagetools create "${tags[@]}" "${sources[@]}"
  manifest="$(docker buildx imagetools inspect "${image}:${VERSION_TAG}" --format '{{json .Manifest}}')"
  actual="$(jq -r '
    .manifests[]
    | select(.platform.os != "unknown")
    | (.platform.os + "/" + .platform.architecture
       + (if .platform.variant then "/" + .platform.variant else "" end))
  ' <<< "$manifest")"
  for platform in "${EXPECTED_PLATFORMS[@]}"; do
    grep -qx "$platform" <<< "$actual"
  done
  jq -r '.digest' <<< "$manifest"
}

GHCR_DIGEST="$(merge_registry "$GHCR_IMAGE" ghcr)"
DOCKERHUB_DIGEST="$(merge_registry "$DOCKERHUB_IMAGE" dockerhub)"
printf 'ghcr_digest=%s\ndockerhub_digest=%s\n' "$GHCR_DIGEST" "$DOCKERHUB_DIGEST" >> "$GITHUB_OUTPUT"
printf 'GHCR digest: %s\nDocker Hub digest: %s\n' "$GHCR_DIGEST" "$DOCKERHUB_DIGEST"
