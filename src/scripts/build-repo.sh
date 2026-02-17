#!/usr/bin/env bash

set -euo pipefail

# Create aptly mirrors from per-mirror JSON files, import each mirror's
# packages, and publish the resulting repository.
#
# Expects:
#   - /tmp/src/mirrors/*.json  (one file per mirror)

shopt -s nullglob
files=(/tmp/src/mirrors/*.json)
shopt -u nullglob

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No mirror definitions found."
  exit 0
fi

######################### Create, Update & Import ##############################

aptly repo create -distribution=trixie ws-feature-store

for conf in "${files[@]}"; do
  name=$(basename "$conf" .json)
  url=$(jq -r '.url' "$conf")
  suite=$(jq -r '.suite' "$conf")
  extra=$(jq -r '.extra // empty' "$conf")
  filter=$(jq -r '.packages | join("|")' "$conf")

  mapfile -t comp_array < <(jq -r '.components[]' "$conf")

  aptly mirror create \
    -filter="$filter" -filter-with-deps \
    ${extra:+"$extra"} "$name" "$url" "$suite" "${comp_array[@]}"

  aptly mirror update "$name"

  mapfile -t packages < <(jq -r '.packages[]' "$conf")
  aptly repo import "$name" ws-feature-store -with-deps "${packages[@]}"
done

################################### Publish ####################################

aptly publish repo ws-feature-store

cp /etc/apt/keyrings/kloudkit.gpg /aptly/public/kloudkit.gpg

gpg --no-default-keyring --keyring /etc/apt/keyrings/kloudkit.gpg \
  --export --armor > /aptly/public/kloudkit.asc
