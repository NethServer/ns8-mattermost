#!/bin/bash

# Terminate on error
set -e

MATTERMOST_VERSION=8.1.8
alpine_version=3.19.1
mattermost_ldap_version=2.1

# Prepare variables for later use
images=()
# The image will be pushed to GitHub container registry
repobase="${REPOBASE:-ghcr.io/nethserver}"
# Configure the image name
reponame="mattermost"

# Create a new empty container image
container=$(buildah from scratch)

# Reuse existing nodebuilder-mattermost container, to speed up builds
if ! buildah containers --format "{{.ContainerName}}" | grep -q nodebuilder-mattermost; then
    echo "Pulling NodeJS runtime..."
    buildah from --name nodebuilder-mattermost -v "${PWD}:/usr/src:Z" docker.io/node:18.19.0-alpine
fi

echo "Build static UI files with node..."
buildah run --env="NODE_OPTIONS=--openssl-legacy-provider" --workingdir=/usr/src/ui --env="NODE_OPTIONS=--openssl-legacy-provider" nodebuilder-mattermost sh -c "yarn install && yarn build"

# Add imageroot directory to the container image
buildah add "${container}" imageroot /imageroot
buildah add "${container}" ui/dist /ui
# Setup the entrypoint, ask to reserve one TCP port with the label and set a rootless container
buildah config --entrypoint=/ \
    --label="org.nethserver.authorizations=node:fwadm traefik@node:routeadm" \
    --label="org.nethserver.tcp-ports-demand=3" \
    --label="org.nethserver.udp-ports-demand=1" \
    --label="org.nethserver.rootfull=0" \
    --label="org.nethserver.images=docker.io/postgres:13.13-alpine docker.io/mattermost/mattermost-team-edition:$MATTERMOST_VERSION ghcr.io/nethserver/mattermost-ldap:${IMAGETAG}" \
    "${container}"
# Commit the image
buildah commit "${container}" "${repobase}/${reponame}"

# Append the image URL to the images array
images+=("${repobase}/${reponame}")


# Create mattermost-ldap image
reponame="mattermost-ldap"
container=$(buildah from  docker.io/library/alpine:${alpine_version})
buildah config --env MATTERMOST_LDAP=${mattermost_ldap_version} "${container}"
buildah run "${container}" /bin/sh <<'EOF'
set -e
apk add --no-cache \
  curl \
  nginx \
  php83 \
  php83-fpm \
  supervisor \
  php83-pgsql \
  php83-ldap \
  php83-pdo_pgsql \
  php83-pdo \
  php83-session \
  php83-xml
(
  # dowload code from github
  wget https://github.com/Crivaledaz/Mattermost-LDAP/archive/refs/tags/v${MATTERMOST_LDAP}.tar.gz -O /tmp/mattermost-ldap.tar.gz
  tar -xzf /tmp/mattermost-ldap.tar.gz -C /tmp
  mkdir -p /var/www/html/oauth
  cp -r /tmp/Mattermost-LDAP-*/oauth/* /var/www/html/oauth/

  mkdir -p /etc/nginx/conf.d
  mkdir -p /etc/supervisor/conf.d/
)
# cleaning
rm -rf /tmp/* /var/tmp/* /var/cache/*
EOF
buildah add "${container}" mattermost-ldap/nginx.conf /etc/nginx/nginx.conf
buildah add "${container}" mattermost-ldap/oauth.conf /etc/nginx/conf.d/oauth.conf
buildah add "${container}" mattermost-ldap/config_db.php /var/www/html/oauth/config_db.php
buildah add "${container}" mattermost-ldap/www.conf /etc/php83/php-fpm.d/www.conf
buildah add "${container}" mattermost-ldap/custom.ini /etc/php83/conf.d/custom.ini
buildah add "${container}" mattermost-ldap/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
buildah add "${container}" mattermost-ldap/config_ldap.php /var/www/html/oauth/LDAP/config_ldap.php

buildah config \
    --workingdir="/var/www/html" \
    --port 80/tcp \
    --cmd='["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]' \
    --label="org.opencontainers.image.source=https://github.com/NethServer/ns8-mattermost" \
    --label="org.opencontainers.image.authors=Stephane de Labrusse <stephdl@de-labrusse.fr>" \
    --label="org.opencontainers.image.title=Mattermost-LDAP based on alpine" \
    --label="org.opencontainers.image.description=Mattermost-LDAP is from  https://github.com/Crivaledaz/Mattermost-LDAP/tree/master" \
    --label="org.opencontainers.image.licenses=GPL-3.0-or-later" \
    --label="org.opencontainers.image.url=https://github.com/NethServer/ns8-mattermost" \
    --label="org.opencontainers.image.documentation=https://github.com/NethServer/ns8-mattermost/blob/main/README.md" \
    --label="org.opencontainers.image.vendor=NethServer" \
    "${container}"
# Commit the image
buildah commit "${container}" "${repobase}/${reponame}"

# Append the image URL to the images array
images+=("${repobase}/${reponame}")

#
# NOTICE:
#
# It is possible to build and publish multiple images.
#
# 1. create another buildah container
# 2. add things to it and commit it
# 3. append the image url to the images array
#

#
# Setup CI when pushing to Github.
# Warning! docker::// protocol expects lowercase letters (,,)
if [[ -n "${CI}" ]]; then
    # Set output value for Github Actions
    printf "images=%s\n" "${images[*],,}" >> "${GITHUB_OUTPUT}"
else
    # Just print info for manual push
    printf "Publish the images with:\n\n"
    for image in "${images[@],,}"; do printf "  buildah push %s docker://%s:%s\n" "${image}" "${image}" "${IMAGETAG:-latest}" ; done
    printf "\n"
fi
