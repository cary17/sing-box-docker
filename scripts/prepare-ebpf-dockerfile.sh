#!/usr/bin/env bash
# Dockerfile anchors intentionally use literal $, command substitutions and trailing backslashes.
# shellcheck disable=SC1003,SC2016
set -euo pipefail

INPUT="${1:?usage: prepare-ebpf-dockerfile.sh <input> <output>}"
OUTPUT="${2:?usage: prepare-ebpf-dockerfile.sh <input> <output>}"

[[ -f "$INPUT" ]] || { echo "Dockerfile not found: $INPUT" >&2; exit 1; }
[[ "$INPUT" != "$OUTPUT" ]] || { echo "input and output must differ" >&2; exit 1; }

TEMP="$(mktemp "${OUTPUT}.XXXXXX")"
trap 'rm -f "$TEMP"' EXIT

from_count=0
cgo_count=0
packages_count=0
tags_count=0
dist_count=0

while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    'FROM --platform=$BUILDPLATFORM '*" AS builder")
      line="${line/\$BUILDPLATFORM/\$TARGETPLATFORM}"
      ((from_count += 1))
      ;;
    'ENV CGO_ENABLED=0')
      line='ENV CGO_ENABLED=1'
      ((cgo_count += 1))
      ;;
    '    && apk add git build-base \')
      line='    && apk add git build-base clang linux-headers \'
      ((packages_count += 1))
      ;;
    '    && export TAGS=$(cat release/DEFAULT_BUILD_TAGS_OTHERS) \')
      line='    && export TAGS="$(cat release/DEFAULT_BUILD_TAGS_OTHERS),with_ebpf" \'
      printf '%s\n' "$line" >> "$TEMP"
      printf '%s\n' '    && make -C common/ebpf generate \' >> "$TEMP"
      ((tags_count += 1))
      continue
      ;;
    'FROM --platform=$TARGETPLATFORM alpine AS dist')
      printf '%s\n' 'RUN /go/bin/sing-box version > /tmp/version \' >> "$TEMP"
      printf '%s\n' "    && sed -n 's/^Tags: //p' /tmp/version | tr ',' '\\n' | grep -Fx 'with_ebpf' \\" >> "$TEMP"
      printf '%s\n' "    && grep -Fx 'CGO: enabled' /tmp/version" >> "$TEMP"
      ((dist_count += 1))
      ;;
  esac
  printf '%s\n' "$line" >> "$TEMP"
done < "$INPUT"

for check in \
  "builder platform:$from_count" \
  "CGO setting:$cgo_count" \
  "builder packages:$packages_count" \
  "build tags:$tags_count" \
  "distribution stage:$dist_count"; do
  name="${check%%:*}"
  count="${check##*:}"
  [[ "$count" == 1 ]] || {
    echo "upstream Dockerfile changed: expected one ${name} anchor, found ${count}" >&2
    exit 1
  }
done

grep -Fqx 'ENV CGO_ENABLED=1' "$TEMP"
grep -Fqx '    && make -C common/ebpf generate \' "$TEMP"
grep -Fq 'with_ebpf' "$TEMP"
grep -Fq "grep -Fx 'CGO: enabled'" "$TEMP"

mv "$TEMP" "$OUTPUT"
trap - EXIT
sha256sum "$INPUT" "$OUTPUT"
