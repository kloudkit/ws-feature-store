#!/usr/bin/env bash

set -euo pipefail

# Import the kloudkit GPG private key and all keyring files into trustedkeys.gpg
# so aptly can verify mirror signatures.
#
# Expects:
#   - /run/secrets/GPG_KLOUDKIT_PRIVATE  (Docker build secret)
#   - /tmp/mirrors/*.conf                (mirror conf files)

gpg --batch --import /run/secrets/GPG_KLOUDKIT_PRIVATE

gpg_list=$(mktemp)
trap 'rm -f "$gpg_list"' EXIT

for conf in /tmp/mirrors/*.conf; do
  gpg_url=$(grep "^gpg=" "$conf" | cut -d= -f2- || true)
  [[ -z "$gpg_url" ]] && continue
  name=$(basename "$conf" .conf)
  printf '%s\t%s\n' "$name" "$gpg_url" >> "$gpg_list"
done

/usr/libexec/kloudkit/install-apt-keyring -f "$gpg_list"

for gpg_file in /usr/share/keyrings/debian-archive-keyring.gpg \
                /etc/apt/keyrings/*.gpg; do
  gpg --no-default-keyring --keyring "$gpg_file" --export \
    | gpg --no-default-keyring --keyring trustedkeys.gpg --import
done

gpg --no-default-keyring --keyring trustedkeys.gpg \
  --keyserver keyserver.ubuntu.com \
  --recv-keys 254B391D8CACCBF8
