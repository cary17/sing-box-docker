#!/usr/bin/env bash

version_key() {
  local tag="$1" prerelease_rank number
  local LC_ALL=C
  if [[ ! "$tag" =~ ^[vV]?([0-9]+)\.([0-9]+)\.([0-9]+)(-([A-Za-z]+)\.([0-9]+))?-reF1nd(\.([0-9]+))?$ ]]; then
    printf 'invalid version: %s\n' "$tag" >&2
    return 1
  fi

  case "${BASH_REMATCH[5],,}" in
    '') prerelease_rank=4 ;;
    alpha) prerelease_rank=1 ;;
    beta) prerelease_rank=2 ;;
    rc) prerelease_rank=3 ;;
    *) prerelease_rank=0 ;;
  esac

  for number in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
    "$prerelease_rank" "${BASH_REMATCH[6]:-0}" "${BASH_REMATCH[8]:-0}"; do
    number="${number#"${number%%[!0]*}"}"
    number="${number:-0}"
    # Compare digit counts before digits; never parse version numbers as integers.
    printf '%020d:%s.' "${#number}" "$number" || return 1
  done
}
