# ns8-mattermost

Start and configure a mattermost instance.
The module uses [Mattermost Docker Image for Team Edition](https://hub.docker.com/r/mattermost/mattermost-team-edition).

## Documentation

The documenation is available at https://docs.mattermost.com/

You could configure the settings by  [Environment variables](https://docs.mattermost.com/configure/environment-configuration-settings.html), the container must be restarted once the Env vars has been changed

## Install

Instantiate the module with:

    add-module ghcr.io/nethserver/mattermost:latest 1

The output of the command will return the instance name.
Output example:

    {"module_id": "mattermost1", "image_name": "mattermost", "image_url": "ghcr.io/nethserver/mattermost:latest"}

## Configure

Let's assume that the mattermost instance is named `mattermost1`.

Launch `configure-module`, by setting the following parameters:
- `host`: a fully qualified domain name for the application
- `http2https`: enable or disable HTTP to HTTPS redirection
- `lets_encrypt`: enable or disable Let's Encrypt certificate

Example:

```
api-cli run module/mattermost1/configure-module --data - <<EOF
{
  "host": "mattermost.domain.com",
  "http2https": true,
  "lets_encrypt": false
}
EOF
```

The above command will:
- start and configure the mattermost instance
- configure a virtual host for trafik to access the instance

## Get the configuration

You can retrieve the configuration with

```
api-cli run get-configuration --agent module/mattermost1 --data null | jq
```

## Access the database

You can access the database of a running instance using this command:
```
podman exec -ti postgres-app psql -U mattuser
```

## Smarthost discovery

Mattermost registers to the event smarthost-changed, each time you enable or disable the smarthost settings in the node, you restart mattermost.
Before to start the containers we trigger the script discover-smarthost to find and write to an environment file `smarthost.env` the settings of the smarthost and enable the email notification.

## Uninstall

To uninstall the instance:

    remove-module --no-preserve mattermost1

## Testing

Test the module using the `test-module.sh` script:


    ./test-module.sh <NODE_ADDR> ghcr.io/nethserver/mattermost:latest

The tests are made using [Robot Framework](https://robotframework.org/)

## UI translation

Translated with [Weblate](https://hosted.weblate.org/projects/ns8/).

To setup the translation process:

- add [GitHub Weblate app](https://docs.weblate.org/en/latest/admin/continuous.html#github-setup) to your repository
- add your repository to [hosted.weblate.org](https://hosted.weblate.org) or ask a NethServer developer to add it to ns8 Weblate project
