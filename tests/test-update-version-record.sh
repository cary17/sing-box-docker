#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/update-version-record.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
export GITHUB_REF_NAME=main
printf -v SHA '%040d' 1
printf -v HASH '%064d' 2
ARGS=(stable v1.2.3-reF1nd 2026-01-01T00:00:00Z v1.2.3 reF1nd-stable "$SHA" "$HASH" "$HASH" "sha256:$HASH" "sha256:$HASH")

git init -q --bare --initial-branch=main "$TMP/remote"
git clone -q "$TMP/remote" "$TMP/seed" 2>/dev/null
mkdir -p "$TMP/seed/.github/version"
printf '%s\n' '{"channel":"stable","version":"v1.0.0"}' > "$TMP/seed/.github/version/stable.json"
printf '%s\n' '{"channel":"testing","version":"v1.0.0"}' > "$TMP/seed/.github/version/testing.json"
git -C "$TMP/seed" add .
git -C "$TMP/seed" commit -qm initial
git -C "$TMP/seed" push -q origin main
BASE="$(git -C "$TMP/seed" rev-parse HEAD)"
git clone -q "$TMP/remote" "$TMP/worker"
git -C "$TMP/worker" checkout -q --detach "$BASE"
cd "$TMP/worker"

# Every bad boundary fails before touching tracked files, the index or HEAD.
for field in 0 1 2 3 4 5 6 7 8 9; do
  bad=("${ARGS[@]}")
  bad[field]='../invalid'
  if bash "$SCRIPT" "${bad[@]}" >"$TMP/error" 2>&1; then
    echo "invalid field $field accepted" >&2; exit 1
  fi
  [[ "$(git rev-parse HEAD)" == "$BASE" && -z "$(git status --porcelain)" ]]
done
for invalid_date in 2026-02-30T00:00:00Z 2026-01-01T99:00:00Z; do
  bad=("${ARGS[@]}"); bad[2]="$invalid_date"
  if bash "$SCRIPT" "${bad[@]}" >"$TMP/error" 2>&1; then exit 1; fi
  [[ -z "$(git status --porcelain)" ]]
done
if GITHUB_REF_NAME='../bad' bash "$SCRIPT" "${ARGS[@]}" >"$TMP/error" 2>&1; then exit 1; fi
[[ -z "$(git status --porcelain)" ]]
printf 'unrelated\n' > unrelated
git add unrelated
if bash "$SCRIPT" "${ARGS[@]}" >"$TMP/error" 2>&1; then exit 1; fi
[[ "$(git diff --cached --name-only)" == unrelated ]]
[[ "$(git rev-parse HEAD)" == "$BASE" ]]
git restore --staged unrelated
rm unrelated

# Another channel advances the remote after this worker's fixed checkout.
printf '%s\n' '{"channel":"testing","version":"v2.0.0"}' > "$TMP/seed/.github/version/testing.json"
git -C "$TMP/seed" add .
git -C "$TMP/seed" commit -qm 'concurrent testing record'
git -C "$TMP/seed" push -q origin main
bash "$SCRIPT" "${ARGS[@]}" >"$TMP/success" 2>&1 || { cat "$TMP/success" >&2; exit 1; }
[[ -z "$(git branch --show-current)" && -z "$(git status --porcelain)" ]]
git --git-dir="$TMP/remote" show main:.github/version/stable.json | jq -e --arg sha "$SHA" '.channel == "stable" and .docker_tag == "v1.2.3" and .source_commit == $sha' >/dev/null
git --git-dir="$TMP/remote" show main:.github/version/testing.json | jq -e '.version == "v2.0.0"' >/dev/null

# Record validation must accept every supported version prefix.
for version in V1.2.3-reF1nd 1.2.3-reF1nd; do
  ARGS[1]="$version"
  bash "$SCRIPT" "${ARGS[@]}" >"$TMP/prefix" 2>&1 || { cat "$TMP/prefix" >&2; exit 1; }
  git --git-dir="$TMP/remote" show main:.github/version/stable.json |
    jq -e --arg version "$version" '.version == $version' >/dev/null
done

# Real server-side push rejection must propagate; no false published result.
BEFORE="$(git --git-dir="$TMP/remote" rev-parse main)"
printf '#!/bin/sh\nexit 1\n' > "$TMP/remote/hooks/pre-receive"
chmod +x "$TMP/remote/hooks/pre-receive"
ARGS[1]=v1.2.4-reF1nd; ARGS[3]=v1.2.4
if bash "$SCRIPT" "${ARGS[@]}" >"$TMP/rejected" 2>&1; then
  echo 'rejected push reported success' >&2; exit 1
fi
[[ "$(git --git-dir="$TMP/remote" rev-parse main)" == "$BEFORE" ]]
[[ -z "$(git status --porcelain)" ]]

# Failed JSON generation must leave the old record intact and remove its temp file.
mkdir "$TMP/bin"
printf '#!/bin/sh\nprintf partial\nexit 1\n' > "$TMP/bin/jq"
chmod +x "$TMP/bin/jq"
BEFORE="$(sha256sum .github/version/stable.json)"
if PATH="$TMP/bin:$PATH" bash "$SCRIPT" "${ARGS[@]}" >"$TMP/write-error" 2>&1; then exit 1; fi
[[ "$(sha256sum .github/version/stable.json)" == "$BEFORE" ]]
[[ -z "$(git status --porcelain)" ]]
echo 'version record checks passed'
