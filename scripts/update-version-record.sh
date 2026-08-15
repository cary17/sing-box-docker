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
FILE=".github/version/${CHANNEL}.json"

mkdir -p .github/version
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
  } + (if $ebpf_dockerfile_sha256 == "" then {} else {ebpf_dockerfile_sha256: $ebpf_dockerfile_sha256} end)' > "$FILE"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add "$FILE"
if ! git diff --cached --quiet; then
  git commit -m "chore: update ${CHANNEL} version [skip ci]"
  for attempt in 1 2 3; do
    git pull --rebase origin "${GITHUB_REF_NAME}"
    if git push; then
      break
    fi
    [[ "$attempt" -lt 3 ]] || exit 1
    sleep 5
  done
fi

git fetch origin "${GITHUB_REF_NAME}"
REMOTE="$(git show "origin/${GITHUB_REF_NAME}:${FILE}")"
jq -e \
  --arg version "$VERSION" \
  --arg published_at "$PUBLISHED_AT" \
  --arg source_branch "$SOURCE_BRANCH" \
  --arg source_commit "$SOURCE_COMMIT" \
  --arg dockerfile_sha256 "$DOCKERFILE_SHA256" \
  --arg ebpf_dockerfile_sha256 "$EBPF_DOCKERFILE_SHA256" \
  --arg ghcr_digest "$GHCR_DIGEST" \
  --arg dockerhub_digest "$DOCKERHUB_DIGEST" \
  '.version == $version
   and .published_at == $published_at
   and .source_branch == $source_branch
   and .source_commit == $source_commit
   and .dockerfile_sha256 == $dockerfile_sha256
   and .ghcr_digest == $ghcr_digest
   and .dockerhub_digest == $dockerhub_digest
   and ($ebpf_dockerfile_sha256 == "" or .ebpf_dockerfile_sha256 == $ebpf_dockerfile_sha256)' <<< "$REMOTE" >/dev/null
