#!/usr/bin/env bash

set -euo pipefail

# Download artifact files from per-artifact JSON definitions and place them
# under /artifacts/<name>/ for serving by nginx.
#
# Expects:
#   - /tmp/src/artifacts/*.json  (one file per artifact, optional)

mkdir -p /artifacts

shopt -s nullglob
files=(/tmp/src/artifacts/*.json)
shopt -u nullglob

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No artifact definitions found, skipping."
  exit 0
fi

################################ Download Files ################################

for conf in "${files[@]}"; do
  name=$(jq -r '.name' "$conf")
  echo "==> Artifact: $name"

  while IFS=$'\t' read -r url filename sha256; do
    dest="/artifacts/$name/$filename"
    mkdir -p "$(dirname "$dest")"
    echo "  Downloading $filename"
    curl -fsSL -o "$dest" "$url"

    if [[ -n "$sha256" ]]; then
      actual=$(sha256sum "$dest" | cut -d' ' -f1)
      if [[ "$actual" != "$sha256" ]]; then
        echo "  ERROR: checksum mismatch for $filename" >&2
        echo "    expected: $sha256" >&2
        echo "    actual:   $actual" >&2
        exit 1
      fi
      echo "  Checksum OK"
    fi
  done < <(jq -r '.files[] | [.url, .filename, (.sha256 // "")] | @tsv' "$conf")
done

echo "Artifacts downloaded to /artifacts/"
