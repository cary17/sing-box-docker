#!/usr/bin/env bash
set -euo pipefail

RETENTION_DAYS=30
KEEP_LATEST_RUNS=3
NOW='2026-07-24T00:00:00Z'
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/runs.tsv" <<'EOF'
106	2026-07-23T00:00:00Z
105	2026-07-10T00:00:00Z
104	2026-06-01T00:00:00Z
103	2026-05-01T00:00:00Z
102	2026-04-01T00:00:00Z
EOF

sort -r -k2,2 "$TMP/runs.tsv" -o "$TMP/runs.tsv"
cutoff="$(date -u -d "${NOW} - ${RETENTION_DAYS} days" +%s)"
completed_seen=0

while IFS=$'\t' read -r run_id created_at; do
  completed_seen=$((completed_seen + 1))
  if (( completed_seen <= KEEP_LATEST_RUNS )); then
    printf 'keep-latest\t%s\n' "$run_id"
    continue
  fi

  created_epoch="$(date -u -d "$created_at" +%s)"
  if (( created_epoch >= cutoff )); then
    printf 'keep-recent\t%s\n' "$run_id"
  else
    printf 'delete\t%s\n' "$run_id"
  fi
done < "$TMP/runs.tsv" > "$TMP/actual.tsv"

cat > "$TMP/expected.tsv" <<'EOF'
keep-latest	106
keep-latest	105
keep-latest	104
delete	103
delete	102
EOF

diff -u "$TMP/expected.tsv" "$TMP/actual.tsv"
echo 'cleanup policy tests passed'