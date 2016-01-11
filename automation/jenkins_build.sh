#!/bin/bash
set -e

YOCTO_VERSION=$1
MACHINE=$2
JENKINS_PERSISTENT_WORKDIR=$3
JENKINS_DL_DIR=$JENKINS_PERSISTENT_WORKDIR/shared-downloads
JENKINS_SSTATE_DIR=$JENKINS_PERSISTENT_WORKDIR/$MACHINE/sstate
MAXBUILDS=2

# Sanity checks
if [ "$#" -ne 3 ]; then
    echo "Usage: jenkins_build.sh <YOCTO_VERSION> <MACHINE> <JENKINS_PERSISTENT_WORKDIR>"
    exit 1
fi
if [ -z "$BUILD_NUMBER" ] || [ -z "$sourceBranch" ]; then
    echo "[ERROR] BUILD_NUMBER and sourceBranch variable undefined."
    exit 1
fi

# Get the absolute script location
pushd `dirname $0` > /dev/null 2>&1
SCRIPTPATH=`pwd`
popd > /dev/null 2>&1

# Make sure we are where we have to be
cd $SCRIPTPATH/..

if [ "$metaResinBranch" == "production" ]; then
    # Hack it so production branch builds the machine specific production branch.
    metaResinBranch="${metaResinBranch}-${MACHINE}"
fi

./repo init -u .git -b $sourceBranch -m manifests/resin-board-branch.xml
sed --in-place "s|#{branch}|$metaResinBranch|" .repo/manifests/manifests/resin-board-branch.xml
./repo sync

# Run build
if [ "$sourceBranch" == "production" ]; then
    BARYS_ARGUMENTS_VAR=""
else
    BARYS_ARGUMENTS_VAR="--staging"
fi

./scripts/barys \
    --yocto "$YOCTO_VERSION" \
    --log \
    --remove-build \
    --machine "$MACHINE" \
    --supervisor-tag "$supervisorBranch" \
    ${BARYS_ARGUMENTS_VAR} \
    --shared-downloads "$JENKINS_DL_DIR" \
    --shared-sstate "$JENKINS_SSTATE_DIR" \
    --rm-work

# Write deploy artifacts
# TODO: UPDATE to use the new `build-device-type.json` in the specific type's folder
BUILD_DEPLOY_DIR=deploy
DEVICE_TYPES_JSON=$SCRIPTPATH/../yocto-all/resin-device-types/device-types.json

DEVICE_TYPE_CONFIG=$(jq --raw-output ".[] | select(.yocto.machine == \"${MACHINE}\")" $DEVICE_TYPES_JSON)
DEPLOY_ARTIFACT=$(jq --raw-output '.yocto.deployArtifact' <<<$DEVICE_TYPE_CONFIG)
mkdir -p $BUILD_DEPLOY_DIR
rm -rf $BUILD_DEPLOY_DIR/* # do we have anything there?
mv -v $(readlink --canonicalize $YOCTO_VERSION/build/tmp/deploy/images/$MACHINE/$DEPLOY_ARTIFACT) $BUILD_DEPLOY_DIR/$DEPLOY_ARTIFACT
mv -v $YOCTO_VERSION/build/tmp/deploy/images/$MACHINE/VERSION $BUILD_DEPLOY_DIR
echo "$DEVICE_TYPE_CONFIG" > $BUILD_DEPLOY_DIR/device-type.json
