#!/usr/bin/env bash

set -euo pipefail

# Build a unified manifest.json combining APT packages (from aptly Packages
# files) and downloadable artifacts (from per-artifact JSON definitions).
#
# Expects:
#   - /aptly/public/dists/trixie/main/binary-*/Packages  (from build-repo.sh)
#   - /tmp/src/artifacts/*.json                           (artifact definitions)
#
# Produces:
#   - /manifest.json  (copied to nginx root by Dockerfile)

MANIFEST="/manifest.json"
tmp_apt=$(mktemp)
tmp_art=$(mktemp)
trap 'rm -f "$tmp_apt" "$tmp_art"' EXIT

################################# APT Packages #################################

# Parse each binary-<arch>/Packages file and extract per-package metadata.
# When multiple versions of the same package+architecture exist, keep only the
# highest version (dedup via jq group_by + max_by).

{
  for packages_file in /aptly/public/dists/trixie/main/binary-*/Packages; do
    [ -f "$packages_file" ] || continue
    awk '
      /^Package:/      { pkg = $2 }
      /^Version:/      { ver = $2 }
      /^Architecture:/ { arch = $2 }
      /^Filename:/     { file = $2 }
      /^$/ {
        if (pkg != "") printf "%s\t%s\t%s\t%s\n", pkg, ver, arch, file
        pkg = ""; ver = ""; arch = ""; file = ""
      }
      END {
        if (pkg != "") printf "%s\t%s\t%s\t%s\n", pkg, ver, arch, file
      }
    ' "$packages_file"
  done
} | jq -Rn '
  [ inputs | split("\t") | {
      name: .[0],
      version: .[1],
      architecture: .[2],
      link: .[3],
      type: "apt"
  }]
  | group_by([.name, .architecture])
  | map(max_by(.version))
' > "$tmp_apt"

echo "APT: $(jq 'length' "$tmp_apt") packages"

################################## Artifacts ###################################

shopt -s nullglob
artifact_files=(/tmp/src/artifacts/*.json)
shopt -u nullglob

if [[ ${#artifact_files[@]} -gt 0 ]]; then
  jq -s '
    [ .[] | .name as $name | (.version // null) as $ver | .files[] | {
        name: $name,
        version: $ver,
        architecture: (
          if (.filename | test("amd64")) then "amd64"
          elif (.filename | test("arm64")) then "arm64"
          else null
          end
        ),
        link: ("artifacts/" + $name + "/" + .filename),
        type: "artifact"
    }]
  ' "${artifact_files[@]}" > "$tmp_art"
else
  echo '[]' > "$tmp_art"
fi

echo "Artifacts: $(jq 'length' "$tmp_art") files"

################################### Combine ####################################

jq -n \
  --arg built "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --slurpfile apt "$tmp_apt" \
  --slurpfile art "$tmp_art" \
  '{
    built: $built,
    packages: ([$apt[0][], $art[0][]] | sort_by(.name, .architecture // ""))
  }' > "$MANIFEST"

echo "Manifest written to $MANIFEST ($(jq '.packages | length' "$MANIFEST") entries)"
