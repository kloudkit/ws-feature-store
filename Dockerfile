ARG base_tag=v0.0.5-trixie
ARG nginx_tag=1.29.4

################################## Temp Layer ##################################

FROM ghcr.io/kloudkit/base-image:${base_tag} AS temp

############################### Application layer ##############################

FROM nginx:${nginx_tag}
