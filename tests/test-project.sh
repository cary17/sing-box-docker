#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/build.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Execute the workflow's input normalization and channel routing unchanged.
request="$(awk '
  $0 == "        id: build_request" { inside = 1 }
  inside && /^        run: \|$/ { capture = 1; next }
  capture && /^      - name:/ { exit }
  capture { print }
' "$WORKFLOW")"
[[ -n "$request" ]]
while IFS='|' read -r branch version expected_channel expected_version expected_status; do
  export SELECTED_BRANCH="$branch" REQUESTED_VERSION="$version" GITHUB_OUTPUT="$TMP/request-output"
  : > "$GITHUB_OUTPUT"
  if (cd "$ROOT" && bash -euo pipefail -c "$request") >"$TMP/request.log" 2>&1; then status=0; else status=$?; fi
  [[ "$status" -eq "$expected_status" ]] || { cat "$TMP/request.log" >&2; exit 1; }
  if [[ "$status" -eq 0 ]]; then
    grep -Fxq "channel=$expected_channel" "$GITHUB_OUTPUT"
    grep -Fxq "version=$expected_version" "$GITHUB_OUTPUT"
  else
    [[ ! -s "$GITHUB_OUTPUT" ]]
  fi
done <<'REQUESTS'
both||both||0
stable||stable||0
testing||testing||0
both|1.14.4|stable|v1.14.4-reF1nd|0
stable|V1.14.4-reF1nd.1|stable|v1.14.4-reF1nd.1|0
both|1.15.0-alpha.13|testing|v1.15.0-alpha.13-reF1nd|0
testing|v1.15.0-alpha.13-reF1nd|testing|v1.15.0-alpha.13-reF1nd|0
stable|1.15.0-alpha.13|||1
testing|1.14.4|||1
both|../invalid|||1
both|v1.14.4-reF1nd.bad|||1
REQUESTS
unset REQUESTED_VERSION

# Execute the actual workflow fetch commands after the upstream branch advances.
git init -q --initial-branch=main "$TMP/upstream"
printf 'FROM scratch\n' > "$TMP/upstream/Dockerfile.binary"
git -C "$TMP/upstream" add Dockerfile.binary
git -C "$TMP/upstream" -c user.name=Test -c user.email=test@example.invalid commit -qm initial
PINNED="$(git -C "$TMP/upstream" rev-parse HEAD)"
git -C "$TMP/upstream" tag v1.2.3
git -C "$TMP/upstream" -c user.name=Test -c user.email=test@example.invalid commit -qm advanced --allow-empty
for channel in stable testing; do
  commands="$(awk -v job="build_${channel}:" '
    $0 == "  " job { inside = 1 }
    inside && /if git init src/ { capture = 1 }
    capture { print }
    capture && /checkout --detach FETCH_HEAD/ { exit }
  ' "$WORKFLOW")"
  [[ -n "$commands" ]]
  # Replace GitHub expressions only; execute the production commands unchanged.
  # shellcheck disable=SC2016
  commands="${commands//'${{ env.UPSTREAM_REPO }}'/"$TMP/upstream"}"
  expression="\${{ needs.prepare_${channel}.outputs.source_commit }}"
  commands="${commands//"$expression"/"$PINNED"}"
  mkdir "$TMP/$channel"
  (cd "$TMP/$channel" && bash -eu -c "$commands exit 0; else exit 1; fi") >"$TMP/fetch.log" 2>&1 || {
    cat "$TMP/fetch.log" >&2
    exit 1
  }
  [[ "$(git -C "$TMP/$channel/src" rev-parse HEAD)" == "$PINNED" ]]
  [[ "$(git -C "$TMP/$channel/src" describe --tags)" == v1.2.3 ]]
done

# Pin Dockerfile.binary without running Go; the expected binary version comes
# from the selected release, not the current tip of the Dockerfile branch.
for channel in stable testing; do
  commands="$(awk -v job="prepare_${channel}:" '
    $0 == "  " job { inside = 1 }
    inside && /git clone --depth 1/ { capture = 1 }
    capture { print }
    capture && />> "\$GITHUB_OUTPUT"/ { exit }
  ' "$WORKFLOW")"
  [[ -n "$commands" ]]
  # shellcheck disable=SC2016
  commands="${commands//'${{ env.UPSTREAM_REPO }}'/"$TMP/upstream"}"
  expression="\${{ env.UPSTREAM_${channel^^}_BRANCH }}"
  commands="${commands//"$expression"/main}"
  for version in v1.2.3-reF1nd.1 V1.2.3-reF1nd.1 1.2.3-rc.4-reF1nd.2; do
    dir="$TMP/prepare-$channel-$version"
    mkdir "$dir"
    export GITHUB_OUTPUT="$dir/output" EXPECTED_VERSION="$version"
    (cd "$dir" && bash -euo pipefail -c "$commands") >"$TMP/prepare.log" 2>&1 || {
      cat "$TMP/prepare.log" >&2
      exit 1
    }
    grep -Fxq "source_commit=$(git -C "$TMP/upstream" rev-parse HEAD)" "$GITHUB_OUTPUT"
    grep -Fxq "dockerfile_sha256=$(sha256sum "$dir/src/Dockerfile.binary" | cut -d' ' -f1)" "$GITHUB_OUTPUT"
    grep -Fxq "source_version=${version#[vV]}" "$GITHUB_OUTPUT"
  done
done

[[ "$(grep -Fc 'file: src/Dockerfile.binary' "$WORKFLOW")" -eq 4 ]]
[[ "$(grep -Fc 'run: bash repo-tools/scripts/download-release-binary.sh' "$WORKFLOW")" -eq 2 ]]
if grep -Eq 'go run|Dockerfile.ebpf|platform: linux/(386|arm/)' "$WORKFLOW"; then
  echo 'workflow still uses source builds or unsupported release architectures' >&2
  exit 1
fi

# Execute both production build decisions, including explicit old/same versions.
for channel in stable testing; do
  guard="$(awk -v step="${channel}_check" '
    $0 == "        id: " step { inside = 1 }
    inside && /^        run: \|$/ { capture = 1; next }
    capture { print }
    capture && /echo "need_build=/ { exit }
  ' "$WORKFLOW")"
  [[ -n "$guard" ]]
  for result in newer empty_local same older pinned_same pinned_older pinned_invalid_local forced invalid_current invalid_local; do
    CURRENT=v1.2.3-reF1nd LOCAL=v1.2.2-reF1nd REQUESTED_VERSION="" SELECTED_BRANCH="$channel"
    force=false expected=true
    case "$result" in
      empty_local) LOCAL="";;
      same) LOCAL="$CURRENT"; expected=false;;
      older) LOCAL=v1.2.4-reF1nd; expected=false;;
      pinned_same) LOCAL="$CURRENT"; REQUESTED_VERSION="$CURRENT";;
      pinned_older) LOCAL=v1.2.4-reF1nd; REQUESTED_VERSION="$CURRENT";;
      pinned_invalid_local) LOCAL=invalid; REQUESTED_VERSION="$CURRENT";;
      forced) LOCAL="$CURRENT"; force=true;;
      invalid_current) CURRENT=invalid; expected=error;;
      invalid_local) LOCAL=invalid; expected=error;;
    esac
    export CURRENT LOCAL REQUESTED_VERSION SELECTED_BRANCH GITHUB_OUTPUT="$TMP/check-output"
    : > "$GITHUB_OUTPUT"
    # shellcheck disable=SC2016
    expression='${{ github.event.inputs.force_build }}'
    commands="${guard//"$expression"/"$force"}"
    if (cd "$ROOT" && bash -euo pipefail -c "$commands") >"$TMP/check.log" 2>&1; then
      [[ "$expected" != error ]]
      grep -Fxq "need_build=$expected" "$GITHUB_OUTPUT"
    else
      [[ "$expected" == error ]] || { cat "$TMP/check.log" >&2; exit 1; }
    fi
  done
done

# Pinned runs must skip floating-tag and version-record updates in both channels.
# shellcheck disable=SC2016
[[ "$(grep -Fc 'releases/tags/$REQUESTED_VERSION' "$WORKFLOW")" -eq 2 ]]
[[ "$(grep -Fc "if: needs.check_versions.outputs.requested_version == ''" "$WORKFLOW")" -eq 2 ]]
[[ "$(grep -Fc "needs.check_versions.outputs.requested_version == '' && " "$WORKFLOW")" -eq 2 ]]

echo 'project checks passed'
