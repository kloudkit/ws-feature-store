#!/usr/bin/env bash

set -euo pipefail

# Create aptly mirrors from per-mirror conf files, import each mirror's
# packages, and publish the resulting repository.
#
# Expects:
#   - /tmp/mirrors/*.conf  (one file per mirror)

get_field()    { grep "^${2}=" "$1" | cut -d= -f2- || true; }
get_packages() { sed '/^#/d; /^$/d; /^[a-z_]*=/d' "$1"; }

################################ Create Mirrors ################################

for conf in /tmp/mirrors/*.conf; do
  name=$(basename "$conf" .conf)
  url=$(get_field "$conf" url)
  suite=$(get_field "$conf" suite)
  components=$(get_field "$conf" components)
  extra=$(get_field "$conf" extra)
  filter=$(get_packages "$conf" | paste -sd '|')

  IFS=',' read -ra comp_array <<< "$components"

  aptly mirror create \
    -filter="$filter" -filter-with-deps \
    ${extra:+"$extra"} "$name" "$url" "$suite" "${comp_array[@]}"
done

################################ Update Mirrors ################################

for conf in /tmp/mirrors/*.conf; do
  aptly mirror update "$(basename "$conf" .conf)"
done

############################### Import Packages ################################

aptly repo create -distribution=trixie ws-feature-store

for conf in /tmp/mirrors/*.conf; do
  name=$(basename "$conf" .conf)
  mapfile -t packages < <(get_packages "$conf")
  aptly repo import "$name" ws-feature-store -with-deps "${packages[@]}"
done

################################### Publish ####################################

aptly publish repo ws-feature-store

cp /etc/apt/keyrings/kloudkit.gpg /aptly/public/kloudkit.gpg

gpg --no-default-keyring --keyring /etc/apt/keyrings/kloudkit.gpg \
  --export --armor > /aptly/public/kloudkit.asc
