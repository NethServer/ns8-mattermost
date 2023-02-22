# ns8-mattermost

Start and configure a mattermost instance.
The module uses [Mattermost Docker Image for Team Edition](https://hub.docker.com/r/mattermost/mattermost-team-edition).

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
api-cli run configure-module --agent module/mattermost1 --data - <<EOF
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
- add your repository to [hosted.weblate.org]((https://hosted.weblate.org) or ask a NethServer developer to add it to ns8 Weblate project
