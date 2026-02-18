#!/usr/bin/env bash

set -euo pipefail

# Build the APT repository using apt for dependency resolution and aptly for
# mirroring/publishing.
#
# Phase 1: Configure all upstream mirrors as apt sources, then use apt's
#           resolver (per mirror) to compute the complete dependency tree.
# Phase 2: Create aptly mirrors with expanded filters (deps included
#           explicitly), import packages, and publish.
#
# Expects:
#   - /tmp/src/mirrors/*.json  (one file per mirror)
#   - GPG keyrings already imported by import-trusted-keys.sh

shopt -s nullglob
files=(/tmp/src/mirrors/*.json)
shopt -u nullglob

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No mirror definitions found."
  exit 0
fi

################# Phase 1: Dependency resolution (using apt) ###################

echo "==> Phase 1: Resolving dependencies with apt"

# Clear existing apt configuration so resolution uses only our mirrors and
# is not affected by base-image pins (e.g. priority -1 on X11 packages).
rm -f /etc/apt/sources.list
rm -f /etc/apt/sources.list.d/*.list
rm -f /etc/apt/sources.list.d/*.sources
rm -f /etc/apt/preferences
rm -f /etc/apt/preferences.d/*

# Configure each mirror as an apt source and build URL-to-name lookup
declare -A url_to_mirror
for conf in "${files[@]}"; do
  name=$(basename "$conf" .json)
  url=$(jq -r '.url' "$conf")
  suite=$(jq -r '.suite' "$conf")
  components=$(jq -r '.components | join(" ")' "$conf")
  extra=$(jq -r '.extra // empty' "$conf")

  url_to_mirror["$url"]="$name"

  # Determine the keyring for apt authentication
  keyring="/etc/apt/keyrings/${name}.gpg"
  options=""
  if [[ -f "$keyring" ]]; then
    options="signed-by=$keyring"
  elif [[ -z "$(jq -r '.gpg // empty' "$conf")" ]]; then
    # No GPG key specified — use debian archive keyring (e.g. debian-trixie)
    options="signed-by=/usr/share/keyrings/debian-archive-keyring.gpg"
  fi

  # Parse architecture restriction from aptly extra flags (e.g. -architectures=amd64)
  arch_opt=""
  if [[ "$extra" == *"-architectures="* ]]; then
    arch=$(echo "$extra" | grep -o '\-architectures=[^ ]*' | cut -d= -f2)
    arch_opt="arch=$arch "
  fi

  echo "deb [${arch_opt}${options}] $url $suite $components" \
    > "/etc/apt/sources.list.d/${name}.list"
done

apt-get update -qq

# Resolve each mirror's packages independently. All mirrors are configured as
# apt sources, so cross-repo deps (e.g. PHP from Sury needing libgd3 from
# Debian) are found naturally. Resolving per-mirror avoids conflicts between
# unrelated packages from different mirrors.
#
# mirror_filters: mirror_name -> "pkg1 (>= ver1) | pkg2 (>= ver2) | ..."
# mirror_names:   mirror_name -> "pkg1 pkg2 ..."  (for aptly repo import)
declare -A mirror_filters
declare -A mirror_names
declare -A mirror_fallback  # mirrors that skipped dep resolution (e.g. arch mismatch)
sim_output=$(mktemp)
empty_status=$(mktemp)
: > "$empty_status"
trap 'rm -f "$sim_output" "$empty_status"' EXIT

for conf in "${files[@]}"; do
  name=$(basename "$conf" .json)

  # Extract package names (strip version constraints)
  mapfile -t pkg_names < <(
    jq -r '.packages[] | sub(" *\\(.*\\)$"; "")' "$conf"
  )

  echo "==> Resolving dependencies for mirror '$name' (${#pkg_names[@]} packages)..."

  # Use empty dpkg status so ALL transitive deps are resolved, not just those
  # missing from the builder. The workspace may not have the same packages.
  if ! apt-get install -s --no-install-recommends \
    -o Dir::State::status="$empty_status" \
    "${pkg_names[@]}" > "$sim_output" 2>&1; then
    echo "  Warning: dep resolution unavailable for '$name' on $(dpkg --print-architecture) (packages not in index), using top-level packages only"
    mirror_fallback[$name]=1
    continue
  fi

  # Collect all packages that would be installed (new deps)
  mapfile -t resolved < <(awk '/^Inst /{print $2}' "$sim_output" | sort -u)

  echo "    Resolved ${#resolved[@]} packages (including dependencies)"

  # Map resolved packages to source mirrors using a single batched madison
  # call. Capture version so the aptly filter can pin to it (prevents
  # downloading every historical version of a package).
  while IFS=$'\t' read -r pkg version repo_url; do
    matched=false
    for mirror_url in "${!url_to_mirror[@]}"; do
      if [[ "$repo_url" == "$mirror_url"* ]]; then
        mname="${url_to_mirror[$mirror_url]}"
        mirror_filters[$mname]+="${mirror_filters[$mname]:+ | }${pkg} (>= ${version})"
        mirror_names[$mname]+=" $pkg"
        matched=true
        break
      fi
    done
    if [[ "$matched" == false ]]; then
      echo "    Warning: package '$pkg' from '$repo_url' did not match any mirror"
    fi
  done < <(
    apt-cache madison "${resolved[@]}" 2>/dev/null \
      | awk -F'|' '!seen[$1]++ {
          pkg = $1; gsub(/^ +| +$/, "", pkg)
          ver = $2; gsub(/^ +| +$/, "", ver)
          src = $3; gsub(/^ +| +$/, "", src)
          split(src, a, " ")
          printf "%s\t%s\t%s\n", pkg, ver, a[1]
        }'
  )
done

################# Phase 2: aptly mirror, import, publish #######################

echo "==> Phase 2: Creating aptly mirrors and importing packages"

aptly repo create -distribution=trixie ws-feature-store

for conf in "${files[@]}"; do
  name=$(basename "$conf" .json)
  url=$(jq -r '.url' "$conf")
  suite=$(jq -r '.suite' "$conf")
  extra=$(jq -r '.extra // empty' "$conf")

  mapfile -t comp_array < <(jq -r '.components[]' "$conf")

  # Get resolved packages for this mirror; fall back to JSON top-level packages
  # if dep resolution was skipped (e.g. packages unavailable for current arch).
  filter="${mirror_filters[$name]:-}"
  names="${mirror_names[$name]:-}"
  with_deps=""

  if [[ -z "$filter" ]]; then
    if [[ -z "${mirror_fallback[$name]:-}" ]]; then
      echo "  Skipping mirror '$name': no resolved packages"
      continue
    fi
    filter=$(jq -r '.packages | join(" | ")' "$conf")
    names=$(jq -r '.packages[] | sub(" *\\(.*\\)$"; "")' "$conf" | tr '\n' ' ')
    with_deps="-filter-with-deps"
  fi

  mapfile -t pkg_list < <(echo "$names" | tr ' ' '\n' | grep -v '^$' | sort -u)

  echo "  Creating mirror '$name' with ${#pkg_list[@]} packages"

  aptly mirror create \
    -filter="$filter" \
    ${with_deps:+"$with_deps"} \
    ${extra:+"$extra"} "$name" "$url" "$suite" "${comp_array[@]}"

  aptly mirror update "$name"

  aptly repo import "$name" ws-feature-store "${pkg_list[@]}"
done

################################### Publish ####################################

aptly publish repo ws-feature-store

cp /etc/apt/keyrings/kloudkit.gpg /aptly/public/kloudkit.gpg

gpg --no-default-keyring --keyring /etc/apt/keyrings/kloudkit.gpg \
  --export --armor > /aptly/public/kloudkit.asc
