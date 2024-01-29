#!/bin/bash

# Terminate on error
set -e

MATTERMOST_VERSION=8.1.8

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
    --label="org.nethserver.tcp-ports-demand=2" \
    --label="org.nethserver.udp-ports-demand=1" \
    --label="org.nethserver.rootfull=0" \
    --label="org.nethserver.images=docker.io/postgres:13.13-alpine docker.io/mattermost/mattermost-team-edition:$MATTERMOST_VERSION ghcr.io/nethserver/mattermost-nginx:${IMAGETAG} ghcr.io/nethserver/mattermost-fpm:${IMAGETAG} ghcr.io/nethserver/mattermost-postgres-oauth:${IMAGETAG}" \
    "${container}"
# Commit the image
buildah commit "${container}" "${repobase}/${reponame}"

# Append the image URL to the images array
images+=("${repobase}/${reponame}")

# buid nginx reverse proxy
reponame="mattermost-nginx"
nginx_alpine="nginx:1.25.3-alpine3.18"
container=$(buildah from docker.io/${nginx_alpine})
buildah add "${container}" oauth /var/www/html/oauth
buildah add "${container}" oauth.conf /etc/nginx/conf.d/oauth.conf

# Commit the image
buildah commit "${container}" "${repobase}/${reponame}"

# Append the image URL to the images array
images+=("${repobase}/${reponame}")

# build php-fpm
fpm_version="php:8.0.30-fpm-bullseye"
fpm_image="${repobase}/mattermost-fpm"
sed "s/php:fpm/${fpm_version}/" Dockerfile | buildah bud -f - -t ${fpm_image}
#buildah add "${fpm_image}" oauth /var/www/html/oauth
# Append the image URL to the images array
images+=("${fpm_image}")

# build postgresql
reponame="mattermost-postgres-oauth"
posgresql_image="postgres:15.5-alpine3.18"
container=$(buildah from docker.io/${posgresql_image})
buildah add "${container}" init_postgres.sh /docker-entrypoint-initdb.d/init_postgres.sh
buildah add "${container}" config_init.sh.example /docker-entrypoint-initdb.d/config_init.sh
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
