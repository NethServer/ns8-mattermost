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
buildah config --env PHP_INI_DIR="/etc/php83" --env MATTERMOST_LDAP=${mattermost_ldap_version} "${container}"
buildah run "${container}" /bin/sh <<'EOF'
set -e
apk add --no-cache \
  curl \
  nginx \
  php83 \
  php83-ctype \
  php83-curl \
  php83-dom \
  php83-fileinfo \
  php83-fpm \
  php83-gd \
  php83-intl \
  php83-mbstring \
  php83-mysqli \
  php83-opcache \
  php83-openssl \
  php83-phar \
  php83-session \
  php83-tokenizer \
  php83-xml \
  php83-xmlreader \
  php83-xmlwriter \
  supervisor \
  php83-pgsql \
  php83-ldap \
  php83-pdo_pgsql \
  php83-pdo

(
# dowload code from github
wget https://github.com/Crivaledaz/Mattermost-LDAP/archive/refs/tags/v${MATTERMOST_LDAP}.tar.gz -O /tmp/mattermost-ldap.tar.gz
tar -xzf /tmp/mattermost-ldap.tar.gz -C /tmp
mkdir -p /var/www/html/oauth
cp -r /tmp/Mattermost-LDAP-*/oauth/* /var/www/html/oauth/
)
(
cat <<'EOC' >/etc/nginx/nginx.conf
user  nginx;
worker_processes auto;
error_log stderr warn;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include mime.types;
    default_type application/octet-stream;

    # Define custom log format to include reponse times
    log_format main_timed '$remote_addr - $remote_user [$time_local] "$request" '
                          '$status $body_bytes_sent "$http_referer" '
                          '"$http_user_agent" "$http_x_forwarded_for" '
                          '$request_time $upstream_response_time $pipe $upstream_cache_status';

    access_log /dev/stdout main_timed;
    error_log /dev/stderr notice;

    keepalive_timeout 65;

    # Write temporary files to /tmp so they can be created as a non-privileged user
    client_body_temp_path /tmp/client_temp;
    proxy_temp_path /tmp/proxy_temp_path;
    fastcgi_temp_path /tmp/fastcgi_temp;
    uwsgi_temp_path /tmp/uwsgi_temp;
    scgi_temp_path /tmp/scgi_temp;

    # Hardening
    proxy_hide_header X-Powered-By;
    fastcgi_hide_header X-Powered-By;
    server_tokens off;

    # Enable gzip compression by default
    gzip on;
    gzip_proxied any;
    gzip_types text/plain application/xml text/css text/js text/xml application/x-javascript text/javascript application/json application/xml+rss;
    gzip_vary on;
    gzip_disable "msie6";

    # Include server configs
    include /etc/nginx/conf.d/*.conf;
}
EOC



mkdir -p /etc/nginx/conf.d

# we expand configuration files
cat <<'EOC' >/etc/nginx/conf.d/oauth.conf
server {
  listen   *:80;
  server_name  localhost;
  root         /var/www/html;
  index index.php index.html index.htm;

  error_page 404 /404.html;
      location = /40x.html {
  } 

  error_page 500 502 503 504 /50x.html;
      location = /50x.html {
  }

  location /oauth/access_token {
    try_files $uri  /oauth/index.php;
  }

  location /oauth/authorize {
    try_files $uri /oauth/authorize.php$is_args$args;
  }

  location ~ /oauth/.*\.php$ {
    try_files $uri =404;
    fastcgi_pass unix:/run/php-fpm.sock;
    fastcgi_index index.php;
    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    include fastcgi_params;
  }

  location / {
    try_files $uri $uri/ =404;
  }
}
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

cat <<'EOC' >${PHP_INI_DIR}/php-fpm.d/www.conf
[global]
; Log to stderr
error_log = /dev/stderr

[www]
user = nginx
group = nginx
; The address on which to accept FastCGI requests.
; Valid syntaxes are:
;   'ip.add.re.ss:port'    - to listen on a TCP socket to a specific IPv4 address on
;                            a specific port;
;   '[ip:6:addr:ess]:port' - to listen on a TCP socket to a specific IPv6 address on
;                            a specific port;
;   'port'                 - to listen on a TCP socket to all addresses
;                            (IPv6 and IPv4-mapped) on a specific port;
;   '/path/to/unix/socket' - to listen on a unix socket.
; Note: This value is mandatory.
listen = /run/php-fpm.sock
listen.owner = nginx
listen.group = nginx
; Enable status page
pm.status_path = /fpm-status

; Ondemand process manager
pm = ondemand

; The number of child processes to be created when pm is set to 'static' and the
; maximum number of child processes when pm is set to 'dynamic' or 'ondemand'.
; This value sets the limit on the number of simultaneous requests that will be
; served. Equivalent to the ApacheMaxClients directive with mpm_prefork.
; Equivalent to the PHP_FCGI_CHILDREN environment variable in the original PHP
; CGI. The below defaults are based on a server without much resources. Don't
; forget to tweak pm.* to fit your needs.
; Note: Used when pm is set to 'static', 'dynamic' or 'ondemand'
; Note: This value is mandatory.
pm.max_children = 100

; The number of seconds after which an idle process will be killed.
; Note: Used only when pm is set to 'ondemand'
; Default Value: 10s
pm.process_idle_timeout = 10s;

; The number of requests each child process should execute before respawning.
; This can be useful to work around memory leaks in 3rd party libraries. For
; endless request processing specify '0'. Equivalent to PHP_FCGI_MAX_REQUESTS.
; Default Value: 0
pm.max_requests = 1000

; Make sure the FPM workers can reach the environment variables for configuration
clear_env = no

; Catch output from PHP
catch_workers_output = yes

; Remove the 'child 10 said into stderr' prefix in the log and only show the actual message
decorate_workers_output = no

; Enable ping page to use in healthcheck
ping.path = /fpm-ping
EOC



cat <<'EOC' >${PHP_INI_DIR}/conf.d/custom.ini
[Date]
date.timezone="UTC"
expose_php= Off
EOC


mkdir -p /etc/supervisor/conf.d/

cat <<'EOC' >/etc/supervisor/conf.d/supervisord.conf
[supervisord]
nodaemon=true
logfile=/dev/null
logfile_maxbytes=0
pidfile=/run/supervisord.pid

[program:php-fpm]
command=php-fpm83 -F
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
autorestart=false
startretries=0

[program:nginx]
command=nginx -g 'daemon off;'
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
autorestart=false
startretries=0
EOC

cat <<'EOC' >/var/www/html/index.php
<?php
phpinfo();
EOC

ln -s /usr/bin/php83 /usr/bin/php





)
# cleaning
rm -rf /tmp/* /var/tmp/* /var/cache/*
EOF
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
