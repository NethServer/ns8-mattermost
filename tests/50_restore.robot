*** Settings ***
Resource    mattermost.resource

*** Test Cases ***
Restore mattermost in place
    ${old_module_id} =    Set Variable    ${module_id}
    ${out} =    Run task    cluster/restore-module
    ...    {"repository":"${repository}","path":"mattermost/${module_uuid}","snapshot":"${snapshot}","node":${module_node},"replace":true}
    Should Be Equal    ${out}[module_uuid]    ${module_uuid}
    Should Not Be Equal    ${out}[module_id]    ${old_module_id}
    Set Global Variable    ${module_id}    ${out}[module_id]
    Set Global Variable    ${restored}    ${TRUE}
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
