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
  --mount=src=src/mirrors,dst=/tmp/mirrors \
  --mount=src=src/scripts,dst=/scripts \
  /scripts/import-trusted-keys.sh \
  && /scripts/build-repo.sh

################################### Runtime ###################################

FROM nginx:${nginx_tag}

COPY src/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /aptly/public /usr/share/nginx/html
RUN rm \
  /usr/share/nginx/html/index.html \
  /usr/share/nginx/html/50x.html
