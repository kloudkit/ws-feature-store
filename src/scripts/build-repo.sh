#!/usr/bin/env bash

set -euo pipefail

# Create aptly mirrors from per-mirror JSON files, import each mirror's
# packages, and publish the resulting repository.
#
# Expects:
#   - /tmp/mirrors/*.json  (one file per mirror)

################################ Create Mirrors ################################

for conf in /tmp/mirrors/*.json; do
  name=$(basename "$conf" .json)
  url=$(jq -r '.url' "$conf")
  suite=$(jq -r '.suite' "$conf")
  extra=$(jq -r '.extra // empty' "$conf")
  filter=$(jq -r '.packages | join("|")' "$conf")

  mapfile -t comp_array < <(jq -r '.components[]' "$conf")

  aptly mirror create \
    -filter="$filter" -filter-with-deps \
    ${extra:+"$extra"} "$name" "$url" "$suite" "${comp_array[@]}"
done

################################ Update Mirrors ################################

for conf in /tmp/mirrors/*.json; do
  aptly mirror update "$(basename "$conf" .json)"
done

############################### Import Packages ################################

aptly repo create -distribution=trixie ws-feature-store

for conf in /tmp/mirrors/*.json; do
  name=$(basename "$conf" .json)
  mapfile -t packages < <(jq -r '.packages[]' "$conf")
  aptly repo import "$name" ws-feature-store -with-deps "${packages[@]}"
done

################################### Publish ####################################

aptly publish repo ws-feature-store

cp /etc/apt/keyrings/kloudkit.gpg /aptly/public/kloudkit.gpg

gpg --no-default-keyring --keyring /etc/apt/keyrings/kloudkit.gpg \
  --export --armor > /aptly/public/kloudkit.asc
