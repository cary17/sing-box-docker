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
grep -Fqx 'FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS builder' "$TMP/Dockerfile.ebpf"
grep -Fqx 'ENV CGO_ENABLED=0' "$TMP/Dockerfile.ebpf"
grep -Fqx '    && apk add git build-base \' "$TMP/Dockerfile.ebpf"
# shellcheck disable=SC1003,SC2016
grep -Fqx '    && export TAGS="$(cat release/DEFAULT_BUILD_TAGS_OTHERS),with_ebpf" \' "$TMP/Dockerfile.ebpf"
# shellcheck disable=SC2016
grep -Fqx '    && go build -tags "$TAGS" ./cmd/sing-box' "$TMP/Dockerfile.ebpf"
grep -Fqx "    && grep -Fx 'CGO: disabled' /tmp/version" "$TMP/Dockerfile.ebpf"

# The precompiled BPF objects are committed upstream; the build must NOT regenerate them.
if grep -Fq 'make -C common/ebpf generate' "$TMP/Dockerfile.ebpf"; then
  echo 'upstream Dockerfile unexpectedly regenerates eBPF objects' >&2
  exit 1
fi
if grep -Fq 'clang' "$TMP/Dockerfile.ebpf"; then
  echo 'upstream Dockerfile unexpectedly requires clang' >&2
  exit 1
fi

# Fail closed when the TAGS anchor moves: appending with_ebpf is the whole point.
cp "$TMP/Dockerfile" "$TMP/changed"
sed -i 's/export TAGS=$(cat release\/DEFAULT_BUILD_TAGS_OTHERS)/export TAGS=$(cat release\/CUSTOM_TAGS)/' "$TMP/changed"
if bash "$SCRIPT" "$TMP/changed" "$TMP/should-not-exist" >"$TMP/stdout" 2>"$TMP/stderr"; then
  echo 'changed upstream Dockerfile unexpectedly passed' >&2
  exit 1
fi
grep -Fq 'expected one build tags anchor, found 0' "$TMP/stderr"
[[ ! -e "$TMP/should-not-exist" ]]

# Upstream kept this structure from 2026-03 through 2026-08 while changing the
# Go image version. Accept likely formatting/layout changes when the semantic
# build anchors remain intact.
sed \
  -e 's/golang:1.26-alpine/golang:1.25-alpine/' \
  -e 's|COPY . /src|COPY . /workspace/sing-box|' \
  -e 's|WORKDIR /src|WORKDIR /workspace/sing-box|' \
  -e 's/ENV CGO_ENABLED=0/ENV CGO_ENABLED 0/' \
  -e 's/apk add git build-base/apk add --no-cache git ca-certificates build-base/' \
  -e 's/FROM --platform=$TARGETPLATFORM alpine AS dist/FROM --platform=$TARGETPLATFORM alpine:3.24 AS dist/' \
  "$TMP/Dockerfile" > "$TMP/Dockerfile.changed-layout"
bash "$SCRIPT" "$TMP/Dockerfile.changed-layout" "$TMP/Dockerfile.changed-layout.ebpf" >/dev/null
grep -Fqx 'FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS builder' "$TMP/Dockerfile.changed-layout.ebpf"
grep -Fqx '    && apk add --no-cache git ca-certificates build-base \' "$TMP/Dockerfile.changed-layout.ebpf"
grep -Fqx 'FROM --platform=$TARGETPLATFORM alpine:3.24 AS dist' "$TMP/Dockerfile.changed-layout.ebpf"

echo 'eBPF Dockerfile preparation checks passed'
