#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/download-release-binary.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/bin" "$TMP/fixtures"

cat > "$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
url="" output="" auth=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -o) output="$2"; shift 2;;
    -H) [[ "$2" != Authorization:* ]] || auth="$2"; shift 2;;
    https://*) url="$1"; shift;;
    *) shift;;
  esac
done
if [[ "$url" == "https://api.github.com/repos/reF1nd/sing-box-releases/releases/tags/$TEST_VERSION" ]]; then
  [[ "$auth" == 'Authorization: Bearer test-token' ]]
  [[ "${MOCK_FAILURE:-}" != api ]] || exit 1
  jq -n --arg name "$TEST_ASSET.tar.gz" --arg digest "$TEST_DIGEST" --arg failure "${MOCK_FAILURE:-}" '
    {assets: [{name: $name, digest: $digest}]}
    | if $failure == "missing" then .assets = [] else . end
    | if $failure == "digest" then .assets[0].digest = "sha256:invalid" else . end
  ' > "$output"
elif [[ "$url" == "https://github.com/reF1nd/sing-box-releases/releases/download/$TEST_VERSION/$TEST_ASSET.tar.gz" ]]; then
  [[ -z "$auth" ]]
  [[ "${MOCK_FAILURE:-}" != download ]] || exit 1
  if [[ "${MOCK_FAILURE:-}" == checksum ]]; then
    printf corrupt > "$output"
  else
    cp "$TEST_ARCHIVE" "$output"
  fi
else
  printf 'unexpected URL: %s\n' "$url" >&2
  exit 1
fi
MOCK
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH" GITHUB_TOKEN=test-token
export UPSTREAM_RELEASES_REPO=reF1nd/sing-box-releases

for TEST_VERSION in v1.2.3-reF1nd.1 v1.2.3-rc.4-reF1nd.2; do
  for arch in amd64 arm64; do
    TEST_ASSET="sing-box-${TEST_VERSION#v}-linux-$arch-musl"
    mkdir "$TMP/fixtures/$TEST_ASSET"
    printf 'release binary: %s\n' "$TEST_ASSET" > "$TMP/fixtures/$TEST_ASSET/sing-box"
    TEST_ARCHIVE="$TMP/fixtures/$TEST_ASSET.tar.gz"
    tar -czf "$TEST_ARCHIVE" -C "$TMP/fixtures" "$TEST_ASSET/sing-box"
    TEST_DIGEST="sha256:$(sha256sum "$TEST_ARCHIVE" | cut -d' ' -f1)"
    export TEST_VERSION TEST_ASSET TEST_ARCHIVE TEST_DIGEST
    output="$TMP/output-$TEST_VERSION-$arch"
    bash "$SCRIPT" "$TEST_VERSION" "$arch" "$output" >/dev/null
    cmp "$TMP/fixtures/$TEST_ASSET/sing-box" "$output/sing-box-$arch"
    [[ "$(stat -c %a "$output/sing-box-$arch")" == 755 ]]
    if bash "$SCRIPT" "$TEST_VERSION" "$arch" "$output" >/dev/null 2>&1; then
      echo 'existing binary was overwritten' >&2; exit 1
    fi
  done
done

for failure in api missing digest download checksum archive empty; do
  export MOCK_FAILURE="$failure"
  case "$failure" in
    archive) tar -czf "$TMP/invalid.tar.gz" --files-from /dev/null;;
    empty)
      : > "$TMP/fixtures/$TEST_ASSET/sing-box"
      tar -czf "$TMP/invalid.tar.gz" -C "$TMP/fixtures" "$TEST_ASSET/sing-box"
      ;;
  esac
  if [[ "$failure" == archive || "$failure" == empty ]]; then
    export TEST_ARCHIVE="$TMP/invalid.tar.gz"
    TEST_DIGEST="sha256:$(sha256sum "$TEST_ARCHIVE" | cut -d' ' -f1)"
  fi
  if bash "$SCRIPT" "$TEST_VERSION" arm64 "$TMP/failure-$failure" >"$TMP/log" 2>&1; then
    echo "$failure failure unexpectedly passed" >&2; exit 1
  fi
  [[ ! -e "$TMP/failure-$failure/sing-box-arm64" ]]
done
unset MOCK_FAILURE
if bash "$SCRIPT" '../invalid' amd64 "$TMP/invalid-version" >/dev/null 2>&1; then exit 1; fi
if bash "$SCRIPT" "$TEST_VERSION" 386 "$TMP/invalid-arch" >/dev/null 2>&1; then exit 1; fi

echo 'release binary download checks passed'
