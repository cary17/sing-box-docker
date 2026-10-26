#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?usage: download-release-binary.sh <version> <amd64|arm64> <output-dir>}"
ARCH="${2:?missing architecture}"
OUTPUT_DIR="${3:?missing output directory}"
REPO="${UPSTREAM_RELEASES_REPO:-reF1nd/sing-box-releases}"
# shellcheck source=scripts/version-key.sh
source "$(dirname "${BASH_SOURCE[0]}")/version-key.sh"
version_key "$VERSION" >/dev/null
[[ "$ARCH" == amd64 || "$ARCH" == arm64 ]] || { echo "unsupported architecture: $ARCH" >&2; exit 1; }
[[ ! -e "$OUTPUT_DIR/sing-box-$ARCH" && ! -L "$OUTPUT_DIR/sing-box-$ARCH" ]] || { echo "binary already exists: $OUTPUT_DIR/sing-box-$ARCH" >&2; exit 1; }

# Match the Alpine runtime used by Dockerfile.binary.
ASSET="sing-box-${VERSION#[vV]}-linux-${ARCH}-musl.tar.gz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/metadata" "$TMP/archive" "$TMP/binary"

fetch() {
  curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors \
    --connect-timeout 15 --max-time 120 "$@"
}

HEADERS=(-H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28')
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  HEADERS+=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi
fetch "${HEADERS[@]}" "https://api.github.com/repos/$REPO/releases/tags/$VERSION" -o "$TMP/metadata/release.json"
DIGEST="$(jq -er --arg name "$ASSET" '
  [.assets[] | select(.name == $name)]
  | if length == 1 then .[0].digest else error("expected one release asset: " + $name) end
' "$TMP/metadata/release.json")"
[[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "missing or invalid SHA256 for $ASSET" >&2; exit 1; }

fetch "https://github.com/$REPO/releases/download/$VERSION/$ASSET" -o "$TMP/archive/release.tar.gz"
printf '%s  %s\n' "${DIGEST#sha256:}" "$TMP/archive/release.tar.gz" | sha256sum -c -
# Stream only the expected member; never unpack release paths into the build context.
tar -xzOf "$TMP/archive/release.tar.gz" -- "${ASSET%.tar.gz}/sing-box" > "$TMP/binary/sing-box"
[[ -s "$TMP/binary/sing-box" ]] || { echo "empty binary in $ASSET" >&2; exit 1; }
mkdir -p "$OUTPUT_DIR"
install -m 0755 "$TMP/binary/sing-box" "$OUTPUT_DIR/sing-box-$ARCH"
