#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIRRORS_DIR="${SCRIPT_DIR}/../src/mirrors"

get_field()    { grep "^${2}=" "$1" | cut -d= -f2-; }
get_packages() { sed '/^#/d; /^$/d; /^[a-z_]*=/d' "$1"; }

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

download_index() {
  local url="$1" output="$2"

  for ext in .gz .bz2 .xz ""; do
    case "$ext" in
      .gz)   curl -fsSL "${url}${ext}" 2>/dev/null | gunzip  > "$output" 2>/dev/null && return 0 ;;
      .bz2)  curl -fsSL "${url}${ext}" 2>/dev/null | bunzip2 > "$output" 2>/dev/null && return 0 ;;
      .xz)   curl -fsSL "${url}${ext}" 2>/dev/null | unxz    > "$output" 2>/dev/null && return 0 ;;
      "")    curl -fsSL "${url}"       > "$output" 2>/dev/null && return 0 ;;
    esac
  done

  echo "ERROR: failed to download $url" >&2
  return 1
}

get_latest_version() {
  local pkg="$1" index="$2"

  awk -v pkg="$pkg" '
    /^Package:/ { p = $2 }
    /^Version:/ && p == pkg { print $2 }
  ' "$index" | sort -V | tail -1
}

declare -A INDEX_CACHE

changed=0
for conf in "$MIRRORS_DIR"/*.conf; do
  # Collect packages with version pins from this conf
  mapfile -t pinned < <(get_packages "$conf" | grep -F '(>=' || true)
  [[ ${#pinned[@]} -eq 0 ]] && continue

  url=$(get_field "$conf" url)
  suite=$(get_field "$conf" suite)
  IFS=',' read -ra comp_array <<< "$(get_field "$conf" components)"
  index_url="${url}/dists/${suite}/${comp_array[0]}/binary-amd64/Packages"

  if [[ -z "${INDEX_CACHE[$index_url]+x}" ]]; then
    cache_key="${TMPDIR}/$(echo "$index_url" | md5sum | cut -d' ' -f1)"
    echo "Fetching: $index_url"
    download_index "$index_url" "$cache_key"
    INDEX_CACHE[$index_url]="$cache_key"
  fi
  index="${INDEX_CACHE[$index_url]}"

  for entry in "${pinned[@]}"; do
    pkg="${entry%% *}"
    latest=$(get_latest_version "$pkg" "$index")
    if [[ -z "$latest" ]]; then
      echo "WARN: $pkg not found in index"
      continue
    fi

    current=$(grep -oP "^${pkg} \(>= \K[^)]+(?=\))" "$conf" || true)
    if [[ "$current" == "$latest" ]]; then
      echo "  $pkg: $latest (unchanged)"
    else
      sed -i "s|^${pkg} (>= .*)$|${pkg} (>= ${latest})|" "$conf"
      echo "  $pkg: ${current:-<none>} -> ${latest}"
      changed=1
    fi
  done
done

echo ""
if [[ "$changed" -eq 1 ]]; then
  echo "Updated conf files in $MIRRORS_DIR"
else
  echo "No changes needed"
fi
