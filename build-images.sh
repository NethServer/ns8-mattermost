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
    --label="org.nethserver.tcp-ports-demand=2" \
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
container=$(buildah from docker.io/library/alpine:${alpine_version})
buildah config --env MATTERMOST_LDAP=${mattermost_ldap_version} "${container}"
buildah run "${container}" /bin/sh <<'EOF'
set -e
apk add apache2 php81-apache2 php81-pgsql php81-ldap php81-pdo_pgsql  php81-pdo --no-cache
(
# dowload code from github
wget https://github.com/Crivaledaz/Mattermost-LDAP/archive/refs/tags/v${MATTERMOST_LDAP}.tar.gz -O /tmp/mattermost-ldap.tar.gz
tar -xzf /tmp/mattermost-ldap.tar.gz -C /tmp
mkdir -p /var/www/html/oauth
cp -r /tmp/Mattermost-LDAP-*/oauth/* /var/www/html/oauth/
)
(
# enable rewrite module
sed -i '/LoadModule rewrite_module/s/^#//g' /etc/apache2/httpd.conf
)
(
# we expand configuration files
cat <<'EOC' >/etc/apache2/conf.d/oauth.conf
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    ServerName localhost
    DocumentRoot /var/www/html
    DirectoryIndex index.php index.html index.htm

    <Location "/oauth/access_token">
        RewriteEngine On
        RewriteRule ^/oauth/access_token$ /oauth/index.php [L]
    </Location>

    <Location "/oauth/authorize">
        RewriteEngine On
        RewriteRule ^/oauth/authorize$ /oauth/authorize.php [L,QSA]
    </Location>

    <Directory "/var/www/html">
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

</VirtualHost>
EOC

cat <<'EOC' >/var/www/html/oauth/config_db.php
<?php

$db_port = intval(getenv('db_port')) ?: 5432;
$db_host = getenv('db_host') ?: "127.0.0.1";
$db_name = getenv('db_name') ?: "oauth_db";
$db_type = getenv('db_type') ?: "pgsql";
$db_user = getenv('db_user') ?: "oauth";
$db_pass = getenv('db_pass') ?: "oauth_secure-pass";
$dsn = $db_type . ":dbname=" . $db_name . ";host=" . $db_host . ";port=" . $db_port;

/* Uncomment the line below to set date.timezone to avoid E.Notice raise by strtotime() (in Pdo.php)
 * If date.timezone is not defined in php.ini or with this function, Mattermost could return a bad token request error
 */
//date_default_timezone_set ('Europe/Paris');
EOC

cat <<'EOC' >/var/www/html/oauth/LDAP/config_ldap.php
<?php
// LDAP parameters
$ldap_host = getenv('ldap_host') ?: "ldap://ldap.company.com/";
$ldap_port = intval(getenv('ldap_port')) ?: 389;
$ldap_version = intval(getenv('ldap_version')) ?: 3;
$ldap_start_tls = boolval(getenv('ldap_start_tls')) ?: false;

// Attribute use to identify user on LDAP - ex : uid, mail, sAMAccountName
$ldap_search_attribute = getenv('ldap_search_attribute') ?: "uid";

// variable use in resource.php
$ldap_base_dn = getenv('ldap_base_dn') ?: "ou=People,o=Company";
$ldap_filter = getenv('ldap_filter') ?: "(objectClass=*)";

// ldap service user to allow search in ldap
$ldap_bind_dn = getenv('ldap_bind_dn') ?: "";
$ldap_bind_pass = getenv('ldap_bind_pass') ?: "";
EOC
)
# cleaning
rm -rf /tmp/* /var/tmp/* /var/cache/*
EOF
buildah config \
    --workingdir="/" \
    --cmd='["/usr/sbin/httpd","-D","FOREGROUND"]' \
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
