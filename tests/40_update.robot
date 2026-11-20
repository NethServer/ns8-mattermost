*** Settings ***
Resource    mattermost.resource

*** Test Cases ***
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
