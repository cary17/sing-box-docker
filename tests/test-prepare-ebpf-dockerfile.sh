#!/usr/bin/env bash
# Dockerfile assertions intentionally contain literal $ and trailing backslashes.
# shellcheck disable=SC1003,SC2016
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
grep -Fqx 'FROM --platform=$BUILDPLATFORM ubuntu:24.04@sha256:561618e2c15bf2397621dd04f96926663a3b5616c189cf7e38db7e82f5c538ea AS ebpf-builder' "$TMP/Dockerfile.ebpf"
grep -Fqx 'COPY common/ebpf /src/common/ebpf' "$TMP/Dockerfile.ebpf"
grep -Fqx 'RUN apt-get update \' "$TMP/Dockerfile.ebpf"
grep -Fqx '    && apt-get install -y --no-install-recommends clang make gcc libc6-dev linux-libc-dev \' "$TMP/Dockerfile.ebpf"
grep -Fqx '    && make -C common/ebpf generate \' "$TMP/Dockerfile.ebpf"
grep -Fqx 'FROM --platform=$TARGETPLATFORM golang:1.26-alpine AS builder' "$TMP/Dockerfile.ebpf"
grep -Fqx 'ENV CGO_ENABLED=1' "$TMP/Dockerfile.ebpf"
# shellcheck disable=SC1003
grep -Fqx '    && apk add git build-base linux-headers \' "$TMP/Dockerfile.ebpf"
grep -Fqx 'COPY --from=ebpf-builder /src/common/ebpf/native/cgroup.bpf.o common/ebpf/native/cgroup.bpf.o' "$TMP/Dockerfile.ebpf"
grep -Fqx 'COPY --from=ebpf-builder /src/common/ebpf/native/shared_network.bpf.o common/ebpf/native/shared_network.bpf.o' "$TMP/Dockerfile.ebpf"
# shellcheck disable=SC1003,SC2016
grep -Fqx '    && export TAGS="$(cat release/DEFAULT_BUILD_TAGS_OTHERS),with_ebpf" \' "$TMP/Dockerfile.ebpf"
[[ "$(grep -Fxc '    && make -C common/ebpf generate \' "$TMP/Dockerfile.ebpf")" == 1 ]]
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

# The upstream Dockerfile added this structure in 2026-03 and changed only the
# Go image version (1.25 -> 1.26) through 2026-08. Replay that real change plus
# likely formatting/layout changes while preserving the semantic anchors.
sed \
  -e 's/golang:1.26-alpine/golang:1.25-alpine/' \
  -e 's|COPY . /src|COPY . /workspace/sing-box|' \
  -e 's|WORKDIR /src|WORKDIR /workspace/sing-box|' \
  -e 's/ENV CGO_ENABLED=0/ENV CGO_ENABLED 0/' \
  -e 's/apk add git build-base/apk add --no-cache git ca-certificates build-base/' \
  -e 's/FROM --platform=$TARGETPLATFORM alpine AS dist/FROM --platform=$TARGETPLATFORM alpine:3.24 AS dist/' \
  -e '/ARG TARGETOS TARGETARCH/a ARG EXTRA_BUILD_FLAG=""' \
  "$TMP/Dockerfile" > "$TMP/Dockerfile.changed-layout"
bash "$SCRIPT" "$TMP/Dockerfile.changed-layout" "$TMP/Dockerfile.changed-layout.ebpf" >/dev/null
grep -Fqx 'FROM --platform=$TARGETPLATFORM golang:1.25-alpine AS builder' "$TMP/Dockerfile.changed-layout.ebpf"
grep -Fqx 'WORKDIR /workspace/sing-box' "$TMP/Dockerfile.changed-layout.ebpf"
grep -Fqx '    && apk add --no-cache git ca-certificates build-base linux-headers \' "$TMP/Dockerfile.changed-layout.ebpf"
[[ "$(grep -Fc 'linux-headers' "$TMP/Dockerfile.changed-layout.ebpf")" == 1 ]]
grep -Fqx 'FROM --platform=$TARGETPLATFORM alpine:3.24 AS dist' "$TMP/Dockerfile.changed-layout.ebpf"
grep -Fqx 'COPY --from=ebpf-builder /src/common/ebpf/native/cgroup.bpf.o common/ebpf/native/cgroup.bpf.o' "$TMP/Dockerfile.changed-layout.ebpf"

echo 'eBPF Dockerfile preparation checks passed'
