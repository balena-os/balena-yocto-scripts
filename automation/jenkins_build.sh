#!/bin/bash
set -e

cleanup() {
    echo "[INFO] jenkins_build.sh: Cleanup."

    # Stop docker container
    echo "[INFO] jenkins_build.sh: Cleaning up yocto-build container."
    docker stop yocto-build 2> /dev/null || true
    docker rm --volumes yocto-build 2> /dev/null || true

    if [ "$1" == "fail" ]; then
        exit 1
    fi
}
trap 'cleanup fail' SIGINT SIGKILL

MACHINE=$1
JENKINS_PERSISTENT_WORKDIR=$2
JENKINS_DL_DIR=$JENKINS_PERSISTENT_WORKDIR/shared-downloads
JENKINS_SSTATE_DIR=$JENKINS_PERSISTENT_WORKDIR/$MACHINE/sstate
MAXBUILDS=2

# Sanity checks
if [ "$#" -ne 2 ]; then
    echo "Usage: jenkins_build.sh <MACHINE> <JENKINS_PERSISTENT_WORKDIR>"
    exit 1
fi
if [ -z "$BUILD_NUMBER" ] || [ -z "$WORKSPACE" ] || [ -z "$sourceBranch" ] || [ -z "$metaResinBranch" ] || [ -z "$supervisorTag" ]; then
    echo "[ERROR] BUILD_NUMBER, WORKSPACE, sourceBranch, metaResinBranch and supervisorTag are required."
    exit 1
fi

# Specific staging / production flags
if [[ "$sourceBranch" == "production"* ]]; then
    BARYS_ARGUMENTS_VAR=""
else
    BARYS_ARGUMENTS_VAR="--staging"
fi

# Checkout meta-resin
if [ "$metaResinBranch" == "__ignore__" ]; then
    echo "[INFO] Using the default meta-resin revision (as configured in submodules)."
else
    echo "[INFO] Using special meta-resin revision from build params."
    pushd $WORKSPACE/layers/meta-resin > /dev/null 2>&1
    git fetch --all
    git checkout --force origin/$metaResinBranch
    popd > /dev/null 2>&1
fi

# Make sure shared directories are in place
mkdir -p $JENKINS_DL_DIR
mkdir -p $JENKINS_SSTATE_DIR

# Run build
docker stop yocto-build 2> /dev/null || true
docker rm --volumes yocto-build 2> /dev/null || true
docker run --rm -t \
    -v $WORKSPACE:/yocto/resin-board \
    -v $JENKINS_DL_DIR:/yocto/shared-downloads \
    -v $JENKINS_SSTATE_DIR:/yocto/shared-sstate \
    -e BUILDER_UID=$(id -u) \
    -e BUILDER_GID=$(id -g) \
    --name yocto-build \
    --privileged \
    resin/yocto-build-env \
    /prepare-and-start.sh \
        --log \
        --remove-build \
        --machine "$MACHINE" \
        --supervisor-tag "$supervisorTag" \
        ${BARYS_ARGUMENTS_VAR} \
        --shared-downloads /yocto/shared-downloads \
        --shared-sstate /yocto/shared-sstate \
        --rm-work

# Write deploy artifacts
BUILD_DEPLOY_DIR=$WORKSPACE/deploy
DEVICE_TYPE_JSON=$WORKSPACE/$MACHINE.json
VERSION_HOSTOS=$(cat $WORKSPACE/build/tmp/deploy/images/$MACHINE/VERSION_HOSTOS)

DEPLOY_ARTIFACT=$(jq --raw-output '.yocto.deployArtifact' $DEVICE_TYPE_JSON)
COMPRESSED=$(jq --raw-output '.yocto.compressed' $DEVICE_TYPE_JSON)
ARCHIVE=$(jq --raw-output '.yocto.archive' $DEVICE_TYPE_JSON)
mkdir -p $BUILD_DEPLOY_DIR
rm -rf $BUILD_DEPLOY_DIR/* # do we have anything there?
mv -v $(readlink --canonicalize $WORKSPACE/build/tmp/deploy/images/$MACHINE/$DEPLOY_ARTIFACT) $BUILD_DEPLOY_DIR/$DEPLOY_ARTIFACT
if [ "${COMPRESSED}" == 'true' ]; then
	if [ "${ARCHIVE}" == 'true' ]; then
		(cd $BUILD_DEPLOY_DIR && tar --remove-files  --use-compress-program pigz --directory=$DEPLOY_ARTIFACT -cvf ${DEPLOY_ARTIFACT}.tar.gz .)
	else
		 mv $BUILD_DEPLOY_DIR/$DEPLOY_ARTIFACT $BUILD_DEPLOY_DIR/resin.img
		(cd $BUILD_DEPLOY_DIR && tar --remove-files --use-compress-program pigz -cvf resin.img.tar.gz resin.img)
	fi
fi
if [ -f $(readlink --canonicalize $WORKSPACE/build/tmp/deploy/images/$MACHINE/resin-image-$MACHINE.resinhup-tar) ]; then
    mv -v $(readlink --canonicalize $WORKSPACE/build/tmp/deploy/images/$MACHINE/resin-image-$MACHINE.resinhup-tar) $BUILD_DEPLOY_DIR/resinhup-$VERSION_HOSTOS.tar
else
    echo "WARNING: No resinhup package found."
fi

mv -v $WORKSPACE/build/tmp/deploy/images/$MACHINE/VERSION $BUILD_DEPLOY_DIR
mv -v $WORKSPACE/build/tmp/deploy/images/$MACHINE/VERSION_HOSTOS $BUILD_DEPLOY_DIR
cp $DEVICE_TYPE_JSON $BUILD_DEPLOY_DIR/device-type.json

# Cleanup the build directory
# Keep this after writing all artifacts
rm -rf $WORKSPACE/build
