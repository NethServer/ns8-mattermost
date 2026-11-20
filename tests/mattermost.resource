*** Settings ***
Library    SSHLibrary
Resource    api.resource

*** Variables ***
${IMAGE_URL}             ghcr.io/nethserver/mattermost:latest
${SCENARIO}              install
${ADMIN_USER}    admin
${ADMIN_PASSWORD}    Nethesis,1234
${USER_PASSWORD}    Robot,123456

*** Keywords ***
Retry test
    [Arguments]    ${keyword}
    Wait Until Keyword Succeeds    60 seconds    1 second    ${keyword}

Backend URL is reachable
    ${rc} =    Execute Command    curl -f ${backend_url}
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0

Container is healthy
    ${rc} =    Execute Command    runagent -m ${module_id} podman ps --format={{.Status}} --filter=name=mattermost-app | grep -F '(healthy)'
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0

Mmctl
    [Arguments]    ${args}
    ${out}    ${rc} =    Execute Command    runagent -m ${module_id} podman exec mattermost-app mmctl --local ${args}
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}    0    mmctl ${args} failed: ${out}
    RETURN    ${out}

Module environment
    [Arguments]    ${name}
    ${out} =    Execute Command    runagent -m ${module_id} printenv ${name}
    RETURN    ${out.strip()}

Read the backend route
    ${response} =    Run task     module/traefik1/get-route    {"instance":"${module_id}"}
    Set Global Variable    ${backend_url}    ${response['url']}

Update to the tested image
    ${out}  ${rc} =  Execute Command  api-cli run update-module --data '{"force":true,"module_url":"${IMAGE_URL}","instances":["${module_id}"]}'  return_rc=${True}
    Should Be Equal As Integers  ${rc}  0  action update-module ${IMAGE_URL} failed

Api
    [Arguments]    ${token}    ${method}    ${path}    ${data}={}    ${jq}=.
    ${out}    ${rc} =    Execute Command
    ...    curl -sf -X ${method} -H 'Authorization: Bearer ${token}' -H 'Content-Type: application/json' -d '${data}' ${backend_url.rstrip('/')}/api/v4${path} | jq -r '${jq}'
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}    0    ${method} ${path} failed
    RETURN    ${out}

Log in as
    [Arguments]    ${username}
    ${token} =    Execute Command
    ...    curl -si -X POST -d '{"login_id":"${username}","password":"${USER_PASSWORD}"}' ${backend_url.rstrip('/')}/api/v4/users/login | awk 'tolower($1)=="token:" {print $2}' | tr -d '\\r'
    Should Not Be Empty    ${token}    ${username} cannot log in
    RETURN    ${token}

Post as
    [Arguments]    ${username}    ${message}    ${root_id}=${EMPTY}    ${file_ids}=[]
    ${token} =    Log in as    ${username}
    ${id} =    Api    ${token}    POST    /posts    {"channel_id":"${channel_id}","message":"${message}","root_id":"${root_id}","file_ids":${file_ids}}    .id
    RETURN    ${id}

Test data is present
    ${token} =    Log in as    bob
    ${team_id} =    Api    ${token}    GET    /teams/name/robot-team    jq=.id
    ${cid} =    Api    ${token}    GET    /teams/${team_id}/channels/name/robot-channel    jq=.id
    ${count} =    Api    ${token}    GET    /channels/${cid}/posts    jq=[.posts[] | select(.type == "")] | length
    Should Be Equal As Integers    ${count}    4    the conversation must hold 4 messages
    # Bleve is gone in v11: this goes through the database search.
    ${found} =    Api    ${token}    POST    /teams/${team_id}/posts/search    {"terms":"${search_word}"}    .order | length
    Should Be Equal As Integers    ${found}    1    the search must find the message
    ${facts} =    Run task    module/${module_id}/get-facts    {}
    Should Be Equal As Integers    ${facts}[active_users]    2
    # The attachment lives on the data volume, not in the database.
    ${out} =    Execute Command    curl -sf -H 'Authorization: Bearer ${token}' ${backend_url.rstrip('/')}/api/v4/files/${file_id}
    Should Be Equal    ${out}    ${marker}

The restore has run
    # Without it the checks below would pass against the old module.
    Should Be True    ${restored}    the restore did not complete

Login to cluster-admin
    New Page    https://${NODE_ADDR}/cluster-admin/
    Fill Text    text="Username"    ${ADMIN_USER}
    Click    button >> text="Continue"
    Fill Text    text="Password"    ${ADMIN_PASSWORD}
    Click    button >> text="Log in"
    Wait For Elements State    css=#main-content    visible    timeout=10s

Remove the test backup
    ${bid} =    Get Variable Value    ${backup_id}
    IF    $bid is not None
        Run task    cluster/remove-backup    {"id":${bid}}
    END
    ${created} =    Get Variable Value    ${repository_created}    ${FALSE}
    IF    ${created}
        Run task    cluster/remove-backup-repository    {"id":"${repository}"}
    END
