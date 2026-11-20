*** Settings ***
Resource    mattermost.resource

*** Test Cases ***
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
    Set Global Variable    ${search_word}    lighthouse${stamp}
    ${token} =    Log in as    alice
    ${team_id} =    Api    ${token}    GET    /teams/name/robot-team    jq=.id
    ${cid} =    Api    ${token}    GET    /teams/${team_id}/channels/name/robot-channel    jq=.id
    Set Global Variable    ${channel_id}    ${cid}
    ${root} =    Post as    alice    Hello Bob, the meeting moved to the ${search_word} room
    Post as    bob    Thanks Alice, I will be there    ${root}
    Post as    alice    Great, see you at ten
    ${fid}    ${rc} =    Execute Command
    ...    printf '%s' '${stamp}' | curl -sf -H 'Authorization: Bearer ${token}' -F channel_id=${channel_id} -F 'files=@-;filename=agenda.txt' ${backend_url.rstrip('/')}/api/v4/files | jq -r '.file_infos[0].id'
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}    0    the file upload failed
    Set Global Variable    ${file_id}    ${fid}
    Set Global Variable    ${marker}    ${stamp}
    Post as    alice    Here is the agenda    file_ids=["${file_id}"]
    # Worst case from the v11 upgrade notes: the 10.11 server accepts it, 11.7 refuses to start with it.
    IF    r'${SCENARIO}' == 'update'
        Mmctl    config set TeamSettings.ExperimentalViewArchivedChannels false
    END
    Test data is present
