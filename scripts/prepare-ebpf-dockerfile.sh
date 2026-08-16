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
workdir_count=0
in_builder=false
cgo_count=0
packages_count=0
tags_count=0
dist_count=0

while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    'FROM --platform=$BUILDPLATFORM '*" AS builder")
      printf '%s\n' 'FROM --platform=$BUILDPLATFORM ubuntu:26.04@sha256:678c6550cc43645e08669028bc177f50be4e7c5b8cca677067b1914d4afc7a03 AS ebpf-builder' >> "$TEMP"
      printf '%s\n' 'COPY common/ebpf /src/common/ebpf' >> "$TEMP"
      printf '%s\n' 'WORKDIR /src' >> "$TEMP"
      printf '%s\n' 'RUN apt-get update \' >> "$TEMP"
      printf '%s\n' '    && apt-get install -y --no-install-recommends clang make gcc libc6-dev linux-libc-dev \' >> "$TEMP"
      printf '%s\n' '    && make -C common/ebpf generate \' >> "$TEMP"
      printf '%s\n' '    && rm -rf /var/lib/apt/lists/*' >> "$TEMP"
      line="${line/\$BUILDPLATFORM/\$TARGETPLATFORM}"
      in_builder=true
      ((from_count += 1))
      ;;
    WORKDIR\ *)
      if [[ "$in_builder" != true || "$workdir_count" != 0 ]]; then
        printf '%s\n' "$line" >> "$TEMP"
        continue
      fi
      printf '%s\n' "$line" >> "$TEMP"
      printf '%s\n' 'COPY --from=ebpf-builder /src/common/ebpf/native/cgroup.bpf.o common/ebpf/native/cgroup.bpf.o' >> "$TEMP"
      printf '%s\n' 'COPY --from=ebpf-builder /src/common/ebpf/native/shared_network.bpf.o common/ebpf/native/shared_network.bpf.o' >> "$TEMP"
      ((workdir_count += 1))
      continue
      ;;
    'ENV CGO_ENABLED=0'|'ENV CGO_ENABLED 0')
      line='ENV CGO_ENABLED=1'
      ((cgo_count += 1))
      ;;
    *'apk add '*'build-base'*' \')
      if [[ "$line" != *'linux-headers'* ]]; then
        line="${line% \\} linux-headers \\"
      fi
      ((packages_count += 1))
      ;;
    *'export TAGS='*'release/DEFAULT_BUILD_TAGS_OTHERS'*' \')
      prefix="${line%%export TAGS=*}"
      line="${prefix}"'export TAGS="$(cat release/DEFAULT_BUILD_TAGS_OTHERS),with_ebpf" \'
      printf '%s\n' "$line" >> "$TEMP"
      ((tags_count += 1))
      continue
      ;;
    'FROM --platform=$TARGETPLATFORM alpine'*' AS dist')
      in_builder=false
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
  "builder workdir:$workdir_count" \
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
grep -Fqx 'FROM --platform=$BUILDPLATFORM ubuntu:26.04@sha256:678c6550cc43645e08669028bc177f50be4e7c5b8cca677067b1914d4afc7a03 AS ebpf-builder' "$TEMP"
grep -Fqx 'COPY --from=ebpf-builder /src/common/ebpf/native/cgroup.bpf.o common/ebpf/native/cgroup.bpf.o' "$TEMP"
grep -Fqx 'COPY --from=ebpf-builder /src/common/ebpf/native/shared_network.bpf.o common/ebpf/native/shared_network.bpf.o' "$TEMP"
grep -Fq 'with_ebpf' "$TEMP"
grep -Fq "grep -Fx 'CGO: enabled'" "$TEMP"

mv "$TEMP" "$OUTPUT"
trap - EXIT
sha256sum "$INPUT" "$OUTPUT"
