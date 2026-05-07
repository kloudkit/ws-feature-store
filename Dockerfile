# syntax=docker/dockerfile:1.23

# renovate: datasource=docker depName=ghcr.io/kloudkit/base-image
ARG base_tag=v0.0.7-trixie
# renovate: datasource=docker depName=nginx
ARG nginx_tag=1.30.0-alpine

################################### Builder ###################################

FROM ghcr.io/kloudkit/base-image:${base_tag} AS builder

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    aptly \
    debian-archive-keyring \
    jq \
  && /usr/libexec/kloudkit/apt-cleanup

COPY src/aptly.conf /etc/aptly.conf

RUN --mount=type=secret,id=GPG_KLOUDKIT_PRIVATE \
  --mount=src=src,dst=/tmp/src \
  /tmp/src/scripts/import-trusted-keys.sh \
  && /tmp/src/scripts/build-repo.sh \
  && /tmp/src/scripts/build-artifacts.sh \
  && /tmp/src/scripts/build-manifest.sh

################################### Runtime ###################################

FROM nginx:${nginx_tag}

COPY src/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /aptly/public /usr/share/nginx/html
COPY --from=builder /artifacts /usr/share/nginx/html/artifacts
COPY --from=builder /manifest.json /usr/share/nginx/html/manifest.json

RUN rm \
  /usr/share/nginx/html/index.html \
  /usr/share/nginx/html/50x.html
