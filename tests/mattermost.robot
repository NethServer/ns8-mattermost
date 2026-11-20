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
    Set Suite Variable    ${backend_url}    ${response['url']}

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

*** Test Cases ***
Add module for ${SCENARIO} scenario
    IF    r'${SCENARIO}' == 'update'
        Set Local Variable  ${iurl}  mattermost
    ELSE
        Set Local Variable  ${iurl}  ${IMAGE_URL}
    END
    ${output}  ${rc} =    Execute Command    add-module ${iurl} 1
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    &{output} =    Evaluate    ${output}
    Set Suite Variable    ${module_id}    ${output.module_id}

Take screenshots
    [Tags]    ui
    Import Library    Browser
    New Browser    chromium    headless=True
    New Context    ignoreHTTPSErrors=True
    Login to cluster-admin
    Go To    https://${NODE_ADDR}/cluster-admin/#/apps/${module_id}
    Wait For Elements State    iframe >>> h2 >> text="Status"    visible    timeout=10s
    Sleep    5s
    Take Screenshot    filename=${OUTPUT DIR}/browser/screenshot/1._Status.png
    Go To    https://${NODE_ADDR}/cluster-admin/#/apps/${module_id}?page=settings
    Wait For Elements State    iframe >>> h2 >> text="Settings"    visible    timeout=10s
    Sleep    5s
    Take Screenshot    filename=${OUTPUT DIR}/browser/screenshot/2._Settings.png
    Close Browser

Configure module
    ${rc} =    Execute Command    api-cli run module/${module_id}/configure-module --data '{"host":"mattermost.fqdn.test","http2https":true,"lets_encrypt":false}'
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0
    # Assuming the test is running on a single node cluster
    Read the backend route

Create test data
    Retry test    Backend URL is reachable
    Retry test    Container is healthy
    Mmctl    team create --name robot-team --display-name RobotTeam
    FOR    ${user}    IN    alice    bob
        Mmctl    user create --email ${user}@example.org --username ${user} --password ${USER_PASSWORD}
        Mmctl    team users add robot-team ${user}
    END
    Mmctl    channel create --team robot-team --name robot-channel --display-name RobotChannel
    Mmctl    channel users add robot-team:robot-channel alice bob
    ${stamp} =    Evaluate    str(time.time_ns())    modules=time
    Set Suite Variable    ${search_word}    lighthouse${stamp}
    ${token} =    Log in as    alice
    ${team_id} =    Api    ${token}    GET    /teams/name/robot-team    jq=.id
    ${cid} =    Api    ${token}    GET    /teams/${team_id}/channels/name/robot-channel    jq=.id
    Set Suite Variable    ${channel_id}    ${cid}
    ${root} =    Post as    alice    Hello Bob, the meeting moved to the ${search_word} room
    Post as    bob    Thanks Alice, I will be there    ${root}
    Post as    alice    Great, see you at ten
    ${fid}    ${rc} =    Execute Command
    ...    printf '%s' '${stamp}' | curl -sf -H 'Authorization: Bearer ${token}' -F channel_id=${channel_id} -F 'files=@-;filename=agenda.txt' ${backend_url.rstrip('/')}/api/v4/files | jq -r '.file_infos[0].id'
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}    0    the file upload failed
    Set Suite Variable    ${file_id}    ${fid}
    Set Suite Variable    ${marker}    ${stamp}
    Post as    alice    Here is the agenda    file_ids=["${file_id}"]
    # Worst case from the v11 upgrade notes: the 10.11 server accepts it, 11.7 refuses to start with it.
    IF    r'${SCENARIO}' == 'update'
        Mmctl    config set TeamSettings.ExperimentalViewArchivedChannels false
    END
    Test data is present

Use the node local backup repository
    ${uuid} =    Module environment    MODULE_UUID
    ${node} =    Module environment    NODE_ID
    Set Suite Variable    ${module_uuid}    ${uuid}
    Set Suite Variable    ${module_node}    ${node}
    Set Suite Variable    ${restored}    ${FALSE}
    # A repository URL must be unique: reuse the node's one if it exists.
    ${ip} =    Execute Command    redis-cli hget node/${module_node}/vpn ip_address
    ${url} =    Set Variable    webdav:http://${ip.strip()}:4694
    ${repos} =    Run task    cluster/list-backup-repositories    {}
    ${found} =    Evaluate    [r['id'] for r in $repos['repositories'] if r['url'] == $url]
    IF    ${found}
        Set Suite Variable    ${repository}    ${found}[0]
        Set Suite Variable    ${repository_created}    ${FALSE}
    ELSE
        ${out} =    Run task    cluster/add-backup-repository
        ...    {"provider":"cluster","name":"mattermost-test","url":"${url}","password":"","parameters":{}}
        Set Suite Variable    ${repository}    ${out}[id]
        Set Suite Variable    ${repository_created}    ${TRUE}
    END

Back up mattermost
    # In the update scenario this snapshot holds the previous stable release.
    # run-backup skips a disabled backup, so enable it on a far schedule.
    ${bid} =    Run task    cluster/add-backup
    ...    {"name":"mattermost-test","instances":["${module_id}"],"repository":"${repository}","schedule":"*-12-31 03:17:00","retention":1,"enabled":true}
    Set Suite Variable    ${backup_id}    ${bid}
    Run task    cluster/run-backup    {"id":${backup_id}}
    ${snapshots} =    Run task    cluster/read-backup-snapshots
    ...    {"repository":"${repository}","path":"mattermost/${module_uuid}"}
    Should Not Be Empty    ${snapshots}
    Set Suite Variable    ${snapshot}    ${snapshots}[-1][id]

Update module
    Retry test    Backend URL is reachable
    Log  Scenario ${SCENARIO} with ${IMAGE_URL}  console=${True}
    IF    r'${SCENARIO}' == 'update'
        Update to the tested image
    END

Check if mattermost works as expected
    Retry test    Backend URL is reachable

Check if mattermost-app is marked healthy
    Retry test    Container is healthy

Verify mattermost frontend title
    ${output} =    Execute Command    curl -s ${backend_url}
    Should Contain    ${output}    <title>Mattermost</title>

Test data survives the update
    Wait Until Keyword Succeeds    120 seconds    5 seconds    Test data is present

Restore mattermost in place
    ${old_module_id} =    Set Variable    ${module_id}
    ${out} =    Run task    cluster/restore-module
    ...    {"repository":"${repository}","path":"mattermost/${module_uuid}","snapshot":"${snapshot}","node":${module_node},"replace":true}
    Should Be Equal    ${out}[module_uuid]    ${module_uuid}
    Should Not Be Equal    ${out}[module_id]    ${old_module_id}
    Set Suite Variable    ${module_id}    ${out}[module_id]
    Set Suite Variable    ${restored}    ${TRUE}
    ${rc} =    Execute Command    runagent -m ${old_module_id} true
    ...    return_rc=True    return_stdout=False
    Should Not Be Equal As Integers    ${rc}    0    ${old_module_id} must be gone after a replace
    Read the backend route

Update the restored module
    [Setup]    The restore has run
    # The restore reinstalls the image stored in the backup, so the 10.11 one in the update scenario.
    IF    r'${SCENARIO}' == 'update'
        Wait Until Keyword Succeeds    300 seconds    5 seconds    Container is healthy
        Update to the tested image
    END

Mattermost runs again after the restore
    [Setup]    The restore has run
    Wait Until Keyword Succeeds    300 seconds    5 seconds    Container is healthy
    Retry test    Backend URL is reachable

Test data is restored
    [Setup]    The restore has run
    Test data is present

Remove the test backup
    Run task    cluster/remove-backup    {"id":${backup_id}}
    IF    ${repository_created}
        Run task    cluster/remove-backup-repository    {"id":"${repository}"}
    END

Check if mattermost is removed correctly
    ${rc} =    Execute Command    remove-module --no-preserve ${module_id}
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0
