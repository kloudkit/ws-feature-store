#!/usr/bin/env bash

set -euo pipefail

# Download each artifact file, compute its SHA256 checksum, and update the
# artifact JSON if the checksum has changed. Useful for keeping checksums
# current when upstreams release new versions at stable URLs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS_DIR="${SCRIPT_DIR}/../src/artifacts"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

shopt -s nullglob
files=("$ARTIFACTS_DIR"/*.json)
shopt -u nullglob

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No artifact definitions found."
  exit 0
fi

changed=0
for conf in "${files[@]}"; do
  name=$(jq -r '.name' "$conf")
  echo "==> $name"

  while IFS=$'\t' read -r url filename old_sha; do
    dest="$WORK_DIR/$filename"
    echo "  Downloading $filename"
    curl -fsSL -o "$dest" "$url"
    new_sha=$(sha256sum "$dest" | cut -d' ' -f1)

    if [[ "$old_sha" == "$new_sha" ]]; then
      echo "  $filename: $new_sha (unchanged)"
    else
      tmp=$(mktemp)
      jq --arg fn "$filename" --arg sha "$new_sha" \
        '.files |= map(if .filename == $fn then .sha256 = $sha else . end)' \
        "$conf" > "$tmp" && mv "$tmp" "$conf"
      echo "  $filename: ${old_sha:-<none>} -> $new_sha"
      changed=1
    fi
  done < <(jq -r '.files[] | [.url, .filename, (.sha256 // "")] | @tsv' "$conf")
done

echo ""
if [[ "$changed" -eq 1 ]]; then
  echo "Updated checksums in $ARTIFACTS_DIR"
else
  echo "No changes needed"
fi
