*** Settings ***
Resource    mattermost.resource

*** Test Cases ***
Use the node local backup repository
    ${uuid} =    Module environment    MODULE_UUID
    ${node} =    Module environment    NODE_ID
    Set Global Variable    ${module_uuid}    ${uuid}
    Set Global Variable    ${module_node}    ${node}
    Set Global Variable    ${restored}    ${FALSE}
    # A repository URL must be unique: reuse the node's one if it exists.
    ${ip} =    Execute Command    redis-cli hget node/${module_node}/vpn ip_address
    ${url} =    Set Variable    webdav:http://${ip.strip()}:4694
    ${repos} =    Run task    cluster/list-backup-repositories    {}
    ${found} =    Evaluate    [r['id'] for r in $repos['repositories'] if r['url'] == $url]
    IF    ${found}
        Set Global Variable    ${repository}    ${found}[0]
        Set Global Variable    ${repository_created}    ${FALSE}
    ELSE
        ${out} =    Run task    cluster/add-backup-repository
        ...    {"provider":"cluster","name":"mattermost-test","url":"${url}","password":"","parameters":{}}
        Set Global Variable    ${repository}    ${out}[id]
        Set Global Variable    ${repository_created}    ${TRUE}
    END

Back up mattermost
    # In the update scenario this snapshot holds the previous stable release.
    # run-backup skips a disabled backup, so enable it on a far schedule.
    ${bid} =    Run task    cluster/add-backup
    ...    {"name":"mattermost-test","instances":["${module_id}"],"repository":"${repository}","schedule":"*-12-31 03:17:00","retention":1,"enabled":true}
    Set Global Variable    ${backup_id}    ${bid}
    Run task    cluster/run-backup    {"id":${backup_id}}
    ${snapshots} =    Run task    cluster/read-backup-snapshots
    ...    {"repository":"${repository}","path":"mattermost/${module_uuid}"}
    Should Not Be Empty    ${snapshots}
    Set Global Variable    ${snapshot}    ${snapshots}[-1][id]
