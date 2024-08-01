# balenaOS build + test + deploy reusable workflow

The workflow is triggered on :

1. PR events
2. Creation of a new tagged version - this represents the PR being merged

## On PR events

1. OS is built
2. draft hostapp release is pushed to balena cloud/staging. This is done by doing a `balena deploy` of the hostapp bundle to an app in balena cloud
3. Nothing is deployed to s3 - there's no need currently
4. leviathan tests are run , all 3 suites are in seperate matrix jobs

## On new version tag

1. The merge commit is fetched - and we check that the test jobs passed. We do this because some device types built might not have working test flows/be required to merge a PR
2. OS is re built. This is because right now we can't guarantee that the artifacts from the PR build still exist
3. finalised hostapp release is created given that tests from the merge commit passed. The presence of this finalised hostapp release is what lets the API say there is a new OS version available for that device type. Host os updates fetch the hostapp bundle from these apps
4. artifacts are uploaded to s3 - including the balena OS image - when a user tries to download an OS image, this is where it comes from. The image maker constructs the url pointing to the s3 bucket based on device type, version etc when a user requests an OS image. There is no "direct" link between the hostapp and s3 bucket currently.
5. release assets are attached to the hostapp using the file upload api - these include changelogs and licenses - in the case of device specific artifacts like custom rpi usboot `boot.img` they will also go here
6. If its an esr release, esr tags are added. These tags are used by the api to signal the esr status - like next/sunset
7. Tests are not re-run - they were already run on the PR / commit that was merged

## Architecture diagram

## Input defaults

|                   | PR    | New Tag | New Tag (esr) | Dispatch |
|-------------------|-------|---------|---------------|----------|
| deploy-s3         | false | true    | true          |          |
| deploy-hostapp    | true  | true    | true          |          |
| finalize-hostapp  | false | true    | true          |          |
| check-merge-tests | false | true    | true          |          |
| run-tests         | true  | false   | false         |          |
| deploy-esr        | false | false   | true          |          |

## Flowchart

This flowchart represents the indended logic tree taking into account
various user inputs, event types, and expected results/outputs.

```mermaid
flowchart TD
    Start[Start] --> EventType{Event Type}
    EventType -->|Pull Request| BaseBranch{Base Branch}
    BaseBranch -->|main| DoNotDeployHostApp[Do not deploy hostApp]
    BaseBranch -->|ESR regex| DoNotDeployHostApp
    DoNotDeployHostApp --> PRNoS3[Do not deploy to S3]
    EventType -->|Tag Push| TPTagName{Tag Name}
    TPTagName -->|rolling| TPMain{{Auto Finalize?}}
    TPTagName -->|ESR regex| TPESR{{Auto Finalize?}}
    EventType -->|Workflow Dispatch| WDOnBranch{On Branch}
    WDOnBranch -->|main| WDForceMain{{Force Finalize?}}
    WDOnBranch -->|ESR regex| WDForceESR{{Force Finalize?}}
    WDForceMain -->|yes| WDMainFinal[Deploy hostApp as final]
    WDForceMain -->|no| WDMainDraft[Deploy hostApp as draft]
    WDForceESR -->|yes| WDESRFinal[Deploy hostApp as ESR final]
    WDForceESR -->|no| WDESRDraft[Deploy hostApp as ESR draft]
    WDMainFinal --> WDMainS3Final[Deploy to S3 as final]
    WDMainDraft --> WDNoS3[Do not deploy to S3]
    WDESRDraft --> WDNoS3
    WDESRFinal --> WDESRs3Final[Deploy to S3 as ESR final]
    TPMain -->|yes| TPMainTests{Check last tests}
    TPMainTests -->|passed| TPMainFinal[Deploy hostApp as final]
    TPMainTests -->|failed| TPMainDraft[Deploy hostApp as draft]
    TPMain -->|no| TPMainDraft
    TPESR -->|yes| TPESRTests{Check last tests}
    TPESR -->|no| TPESRDraft[Deploy hostApp as ESR draft]
    TPESRTests -->|passed| TPESRFinal[Deploy hostApp as ESR final]
    TPESRTests -->|failed| TPESRDraft
    TPMainFinal --> TPMainS3Final[Deploy to S3 as final]
    TPMainDraft --> TPNoS3[Do not deploy to S3]
    TPESRDraft --> TPNoS3
    TPESRFinal --> TPESRs3Final[Deploy to S3 as ESR final]

    classDef userInput stroke:#ff3e00,stroke-width:3px;
    class TPMain,TPESR,WDForceMain,WDForceESR userInput;
    classDef final fill:#4caf50,stroke:#45a049,color:#ffffff;
    classDef noDeploy fill:#ff9800,stroke:#f57c00,color:#ffffff;
    classDef draft fill:#64b5f6,stroke:#1e88e5,color:#ffffff;
    class WDMainFinal,WDESRFinal,TPMainFinal,TPESRFinal,WDMainS3Final,WDESRs3Final,TPMainS3Final,TPESRs3Final final;
    class WDMainDraft,WDESRDraft,TPMainDraft,TPESRDraft,PRMain,PRESR draft;
    class PRNoS3,WDNoS3,TPNoS3,DoNotDeployHostApp noDeploy;
```
