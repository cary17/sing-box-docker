#!/usr/bin/env bash
set -euo pipefail

CHANNEL="${1:?missing channel}"
VERSION="${2:?missing version}"
PUBLISHED_AT="${3:?missing published_at}"
DOCKER_TAG="${4:?missing docker tag}"
SOURCE_BRANCH="${5:?missing source branch}"
SOURCE_COMMIT="${6:?missing source commit}"
DOCKERFILE_SHA256="${7:?missing Dockerfile sha256}"
EBPF_DOCKERFILE_SHA256="$8"
GHCR_DIGEST="${9:?missing GHCR digest}"
DOCKERHUB_DIGEST="${10:?missing Docker Hub digest}"
fail() { echo "$*" >&2; exit 1; }
[[ "$#" -eq 10 ]] || fail 'expected 10 arguments'
[[ "$CHANNEL" == stable || "$CHANNEL" == testing ]] || fail 'invalid channel'
# shellcheck source=scripts/version-key.sh
source "$(dirname "${BASH_SOURCE[0]}")/version-key.sh"
version_key "$VERSION" >/dev/null || fail 'invalid version'
[[ "$DOCKER_TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || fail 'invalid Docker tag'
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail 'invalid source commit'
[[ "$DOCKERFILE_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail 'invalid Dockerfile SHA256'
[[ -z "$EBPF_DOCKERFILE_SHA256" || "$EBPF_DOCKERFILE_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail 'invalid eBPF Dockerfile SHA256'
[[ "$GHCR_DIGEST" =~ ^sha256:[0-9a-f]{64}$ && "$DOCKERHUB_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'invalid image digest'
[[ "$PUBLISHED_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$ ]] || fail 'invalid publication date'
date -d "$PUBLISHED_AT" >/dev/null 2>&1 || fail 'invalid publication date'
git check-ref-format "refs/heads/$SOURCE_BRANCH" >/dev/null || fail 'invalid source branch'
git check-ref-format "refs/heads/${GITHUB_REF_NAME:?missing target branch}" >/dev/null || fail 'invalid target branch'
git diff --cached --quiet || fail 'index must be empty before recording a version'
git diff --quiet || fail 'worktree must be clean before recording a version'
FILE=".github/version/${CHANNEL}.json"

mkdir -p .github/version
TEMP_FILE="$(mktemp "${FILE}.XXXXXX")"
trap 'rm -f "$TEMP_FILE"' EXIT
jq -n \
  --arg channel "$CHANNEL" \
  --arg version "$VERSION" \
  --arg published_at "$PUBLISHED_AT" \
  --arg built_at "$(TZ=Asia/Shanghai date +'%Y-%m-%dT%H:%M:%S+08:00')" \
  --arg docker_tag "$DOCKER_TAG" \
  --arg source_branch "$SOURCE_BRANCH" \
  --arg source_commit "$SOURCE_COMMIT" \
  --arg dockerfile_sha256 "$DOCKERFILE_SHA256" \
  --arg ebpf_dockerfile_sha256 "$EBPF_DOCKERFILE_SHA256" \
  --arg ghcr_digest "$GHCR_DIGEST" \
  --arg dockerhub_digest "$DOCKERHUB_DIGEST" \
  '{
    channel: $channel,
    version: $version,
    published_at: $published_at,
    built_at: $built_at,
    docker_tag: $docker_tag,
    source_branch: $source_branch,
    source_commit: $source_commit,
    dockerfile_sha256: $dockerfile_sha256,
    ghcr_digest: $ghcr_digest,
    dockerhub_digest: $dockerhub_digest
  } + (if $ebpf_dockerfile_sha256 == "" then {} else {ebpf_dockerfile_sha256: $ebpf_dockerfile_sha256} end)' > "$TEMP_FILE"
mv "$TEMP_FILE" "$FILE"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add "$FILE"
if ! git diff --cached --quiet; then
  git commit -m "chore: update ${CHANNEL} version [skip ci]"
  for attempt in 1 2 3; do
    git pull --rebase origin "${GITHUB_REF_NAME}"
    if git push origin "HEAD:refs/heads/${GITHUB_REF_NAME}"; then
      break
    fi
    [[ "$attempt" -lt 3 ]] || exit 1
    sleep 5
  done
fi

git fetch origin "refs/heads/${GITHUB_REF_NAME}"
REMOTE="$(git show "FETCH_HEAD:${FILE}")"
jq -e \
  --arg channel "$CHANNEL" \
  --arg docker_tag "$DOCKER_TAG" \
  --arg version "$VERSION" \
  --arg published_at "$PUBLISHED_AT" \
  --arg source_branch "$SOURCE_BRANCH" \
  --arg source_commit "$SOURCE_COMMIT" \
  --arg dockerfile_sha256 "$DOCKERFILE_SHA256" \
  --arg ebpf_dockerfile_sha256 "$EBPF_DOCKERFILE_SHA256" \
  --arg ghcr_digest "$GHCR_DIGEST" \
  --arg dockerhub_digest "$DOCKERHUB_DIGEST" \
  '.channel == $channel
   and .docker_tag == $docker_tag
   and .version == $version
   and .published_at == $published_at
   and .source_branch == $source_branch
   and .source_commit == $source_commit
   and .dockerfile_sha256 == $dockerfile_sha256
   and .ghcr_digest == $ghcr_digest
   and .dockerhub_digest == $dockerhub_digest
   and ($ebpf_dockerfile_sha256 == "" or .ebpf_dockerfile_sha256 == $ebpf_dockerfile_sha256)' <<< "$REMOTE" >/dev/null
