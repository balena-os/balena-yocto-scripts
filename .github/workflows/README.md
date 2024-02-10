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