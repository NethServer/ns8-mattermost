#!/bin/bash

#
# Copyright (C) 2024 Nethesis S.r.l.
# SPDX-License-Identifier: GPL-3.0-or-later
#



# Check if the database exists
if  podman  exec postgres-app psql -U oauth -d oauth_db > /dev/null 2>&1; then
    echo "Database 'oauth_db' already exists."
else
    tmpfile=$(mktemp)
    trap "rm -f \${tmpfile}" EXIT
    cat <<'EOF' >${tmpfile}
#######################################--Functions--###############################################

ok() { echo -e '\e[32m'$1'\e[m'; }
error() { echo -e '\e[31m'$1'\e[m'; }
info() { echo -e '\e[34m'$1'\e[m'; }
warn() { echo -e '\e[33m'$1'\e[m'; }

#######################################--SQL STATEMENT--###########################################

#Tables creation
create_table_oauth_client="CREATE TABLE oauth_clients (client_id VARCHAR(80) NOT NULL, client_secret VARCHAR(80), redirect_uri VARCHAR(2000) NOT NULL, grant_types VARCHAR(80), scope VARCHAR(100), user_id VARCHAR(80), CONSTRAINT clients_client_id_pk PRIMARY KEY (client_id));"
create_table_oauth_access_tokens="CREATE TABLE oauth_access_tokens (access_token VARCHAR(40) NOT NULL, client_id VARCHAR(80) NOT NULL, user_id VARCHAR(255), expires TIMESTAMP NOT NULL, scope VARCHAR(2000), CONSTRAINT access_token_pk PRIMARY KEY (access_token));"
create_table_oauth_authorization_codes="CREATE TABLE oauth_authorization_codes (authorization_code VARCHAR(40) NOT NULL, client_id VARCHAR(80) NOT NULL, user_id VARCHAR(255), redirect_uri VARCHAR(2000), expires TIMESTAMP NOT NULL, scope VARCHAR(2000), CONSTRAINT auth_code_pk PRIMARY KEY (authorization_code));"
create_table_oauth_refresh_tokens="CREATE TABLE oauth_refresh_tokens (refresh_token VARCHAR(40) NOT NULL, client_id VARCHAR(80) NOT NULL, user_id VARCHAR(255), expires TIMESTAMP NOT NULL, scope VARCHAR(2000), CONSTRAINT refresh_token_pk PRIMARY KEY (refresh_token));"
create_table_users="CREATE TABLE users (id SERIAL NOT NULL, username VARCHAR(255) NOT NULL, CONSTRAINT id_pk PRIMARY KEY (id));"
create_table_oauth_scopes="CREATE TABLE oauth_scopes (scope TEXT, is_default BOOLEAN);"

#Client creation
create_client="INSERT INTO oauth_clients (client_id,client_secret,redirect_uri,grant_types,scope,user_id) VALUES ('$client_id','$client_secret','$redirect_uri','$grant_types','$scope','$user_id');"

###################################################################################################

sleep 5

#Creating Oauth role and associated database (need admin account on postgres)
info "Creation of role $db_user and database $db_name ..."
psql -U mattuser -d postgres -c "CREATE DATABASE $db_name;"
psql -U mattuser -d postgres -c "CREATE USER $db_user WITH ENCRYPTED PASSWORD '$db_pass';"
psql -U mattuser -d postgres -c "GRANT ALL PRIVILEGES ON DATABASE $db_name TO $db_user;"
psql -U mattuser -d postgres -c "ALTER DATABASE $db_name OWNER TO $db_user;"

#Creating tables for ouath database (use oauth role)
info "Creation of tables for database $db_name (using $db_user)"
psql -U $db_user -d $db_name -c "$create_table_oauth_client"
psql -U $db_user -d $db_name -c "$create_table_oauth_access_tokens"
psql -U $db_user -d $db_name -c "$create_table_oauth_authorization_codes"
psql -U $db_user -d $db_name -c "$create_table_oauth_refresh_tokens"
psql -U $db_user -d $db_name -c "$create_table_users"
psql -U $db_user -d $db_name -c "$create_table_oauth_scopes"

#Insert new client in the database
info "Insert new client in the database"
psql -U $db_user -d $db_name -c "$create_client"

#Verification
psql -U $db_user -d $db_name -c "SELECT * from oauth_clients WHERE client_id='$client_id';" | grep '(1'

if [ $? ]
then ok "Client has been created ! Oauth Database is configured.\n"
else error "Client has not been created ! Check log below"
fi
EOF
    podman cp ${tmpfile} postgres-app:/usr/bin/postgresql_oauth_creation.sh
    podman  exec postgres-app bash /usr/bin/postgresql_oauth_creation.sh
    echo "Setup complete."
fi
