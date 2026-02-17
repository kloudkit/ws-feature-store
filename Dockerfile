# syntax=docker/dockerfile:1.4

ARG base_tag=v0.0.6-trixie
ARG nginx_tag=1.29.4-alpine

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
  && /tmp/src/scripts/build-artifacts.sh

################################### Runtime ###################################

FROM nginx:${nginx_tag}

COPY src/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /aptly/public /usr/share/nginx/html
COPY --from=builder /artifacts /usr/share/nginx/html/artifacts

RUN rm \
  /usr/share/nginx/html/index.html \
  /usr/share/nginx/html/50x.html
