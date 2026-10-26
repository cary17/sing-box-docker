#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/build.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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

# Execute both production version-check guards, including helper failures.
for channel in stable testing; do
  guard="$(awk -v step="${channel}_check" '
    $0 == "        id: " step { inside = 1 }
    inside && /source scripts\/version-key.sh/ { capture = 1 }
    capture { print }
    capture && /^          fi$/ { exit }
  ' "$WORKFLOW")"
  [[ -n "$guard" ]]
  for result in valid empty_local invalid_current invalid_local; do
    CURRENT=v1.2.3-reF1nd LOCAL=v1.2.2-reF1nd
    case "$result" in
      empty_local) LOCAL="";;
      invalid_current) CURRENT=invalid;;
      invalid_local) LOCAL=invalid;;
    esac
    if (cd "$ROOT" && export CURRENT LOCAL && bash -eu -c "$guard") >/dev/null 2>&1; then
      [[ "$result" == valid || "$result" == empty_local ]]
    else
      [[ "$result" == invalid_current || "$result" == invalid_local ]]
    fi
  done
done

echo 'project checks passed'
