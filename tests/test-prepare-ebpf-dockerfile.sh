#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/prepare-ebpf-dockerfile.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/Dockerfile" <<'DOCKERFILE'
FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS builder
COPY . /src
WORKDIR /src
ARG TARGETOS TARGETARCH
ENV CGO_ENABLED=0
ENV GOOS=$TARGETOS
ENV GOARCH=$TARGETARCH
RUN set -ex \
    && apk add git build-base \
    && export TAGS=$(cat release/DEFAULT_BUILD_TAGS_OTHERS) \
    && go build -tags "$TAGS" ./cmd/sing-box
FROM --platform=$TARGETPLATFORM alpine AS dist
COPY --from=builder /src/sing-box /usr/local/bin/sing-box
DOCKERFILE

bash "$SCRIPT" "$TMP/Dockerfile" "$TMP/Dockerfile.ebpf" >/dev/null
# These are literal Dockerfile lines; shell expansion would invalidate the test.
# shellcheck disable=SC1003,SC2016
grep -Fqx 'FROM --platform=$TARGETPLATFORM golang:1.26-alpine AS builder' "$TMP/Dockerfile.ebpf"
grep -Fqx 'ENV CGO_ENABLED=1' "$TMP/Dockerfile.ebpf"
# shellcheck disable=SC1003
grep -Fqx '    && apk add git build-base clang linux-headers \' "$TMP/Dockerfile.ebpf"
# shellcheck disable=SC1003,SC2016
grep -Fqx '    && export TAGS="$(cat release/DEFAULT_BUILD_TAGS_OTHERS),with_ebpf" \' "$TMP/Dockerfile.ebpf"
# shellcheck disable=SC1003
grep -Fqx '    && make -C common/ebpf generate \' "$TMP/Dockerfile.ebpf"
# shellcheck disable=SC2016
grep -Fqx '    && go build -tags "$TAGS" ./cmd/sing-box' "$TMP/Dockerfile.ebpf"
grep -Fqx "    && grep -Fx 'CGO: enabled' /tmp/version" "$TMP/Dockerfile.ebpf"

cp "$TMP/Dockerfile" "$TMP/changed"
sed -i 's/ENV CGO_ENABLED=0/ENV CGO_ENABLED=1/' "$TMP/changed"
if bash "$SCRIPT" "$TMP/changed" "$TMP/should-not-exist" >"$TMP/stdout" 2>"$TMP/stderr"; then
  echo 'changed upstream Dockerfile unexpectedly passed' >&2
  exit 1
fi
grep -Fq 'expected one CGO setting anchor, found 0' "$TMP/stderr"
[[ ! -e "$TMP/should-not-exist" ]]

echo 'eBPF Dockerfile preparation checks passed'
