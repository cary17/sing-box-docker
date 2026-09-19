#!/usr/bin/env bash

version_key() {
  local tag="${1#v}"
  tag="${tag#V}"
  local base="${tag%%-reF1nd*}"
  local suffix="${tag#*-reF1nd}"
  local version_part prerelease_part prerelease_name major minor patch prerelease_rank prerelease_number revision

  if [[ "$base" == *-* ]]; then
    version_part="${base%%-*}"
    prerelease_part="${base#*-}"
    prerelease_name="${prerelease_part%%.*}"
    case "${prerelease_name,,}" in
      alpha) prerelease_rank=1 ;;
      beta) prerelease_rank=2 ;;
      rc) prerelease_rank=3 ;;
      *) prerelease_rank=0 ;;
    esac
    prerelease_number="${prerelease_part##*.}"
    [[ "$prerelease_number" =~ ^[0-9]+$ ]] || prerelease_number=0
  else
    version_part="$base"
    prerelease_rank=99999999
    prerelease_number=99999999
  fi

  IFS=. read -r major minor patch _ <<< "$version_part"
  if [[ "$suffix" == "$tag" || -z "$suffix" ]]; then
    revision=0
  else
    revision="${suffix#.}"
    [[ "$revision" =~ ^[0-9]+$ ]] || revision=0
  fi

  printf '%08d.%08d.%08d.%08d.%08d.%08d' "${major:-0}" "${minor:-0}" "${patch:-0}" "${prerelease_rank:-0}" "${prerelease_number:-0}" "${revision:-0}"
}
