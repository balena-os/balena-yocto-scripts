#!/bin/bash

set -ex

BUILD_CONTAINER_NAME=yocto-build-$$

cleanup() {
    echo "[INFO] jenkins_build.sh: Cleanup."

    # Stop docker container
    echo "[INFO] jenkins_build.sh: Cleaning up yocto-build container."
    docker stop $BUILD_CONTAINER_NAME 2> /dev/null || true
    docker rm --volumes $BUILD_CONTAINER_NAME 2> /dev/null || true

    if [ "$1" == "fail" ]; then
        exit 1
    fi
}
trap 'cleanup fail' SIGINT SIGTERM

deploy_build () {
	local DEPLOY_DIR="$1"
	local CHECK_COMPRESSED="$2"

	local DEPLOY_ARTIFACT=$(jq --raw-output '.yocto.deployArtifact' $DEVICE_TYPE_JSON)
	local COMPRESSED=$(jq --raw-output '.yocto.compressed' $DEVICE_TYPE_JSON)
	local ARCHIVE=$(jq --raw-output '.yocto.archive' $DEVICE_TYPE_JSON)

	rm -rf "$DEPLOY_DIR"
	mkdir -p "$DEPLOY_DIR/image"

	cp -v "$YOCTO_BUILD_DEPLOY/VERSION" "$DEPLOY_DIR"
	cp -v "$YOCTO_BUILD_DEPLOY/VERSION_HOSTOS" "$DEPLOY_DIR"
	cp -v "$DEVICE_TYPE_JSON" "$DEPLOY_DIR/device-type.json"

	if [ $SLUG != "edge" ]; then
		cp -v "$YOCTO_BUILD_DEPLOY/kernel_modules_headers.tar.gz" "$DEPLOY_DIR"

		if [ "$CHECK_COMPRESSED" == "true" ]; then
			if [ "${COMPRESSED}" == 'true' ]; then
				if [ "${ARCHIVE}" == 'true' ]; then
					cp -v "$YOCTO_BUILD_DEPLOY/$DEPLOY_ARTIFACT" "$DEPLOY_DIR/image/$DEPLOY_ARTIFACT"
					(cd "$DEPLOY_DIR/image" && tar --remove-files --use-compress-program pigz --directory="$DEPLOY_DIR/image/$DEPLOY_ARTIFACT" -cvf "$DEPLOY_ARTIFACT.tar.gz" .)
				else
					cp -v $(readlink --canonicalize "$YOCTO_BUILD_DEPLOY/$DEPLOY_ARTIFACT") "$DEPLOY_DIR/image/resin.img"
					(cd "$DEPLOY_DIR/image" && tar --remove-files --use-compress-program pigz -cvf resin.img.tar.gz resin.img)
				fi
			else
				cp -v $(readlink --canonicalize "$YOCTO_BUILD_DEPLOY/$DEPLOY_ARTIFACT") "$DEPLOY_DIR/image/resin.img"
			fi
		else
			if [ -d "$YOCTO_BUILD_DEPLOY/$DEPLOY_ARTIFACT" ]; then
				cp -rv "$YOCTO_BUILD_DEPLOY/$DEPLOY_ARTIFACT"/* "$DEPLOY_DIR/image"
			else
				cp -v $(readlink --canonicalize "$YOCTO_BUILD_DEPLOY/$DEPLOY_ARTIFACT") "$DEPLOY_DIR/image/resin.img"
			fi
		fi
	fi
}

MACHINE=$1
JENKINS_PERSISTENT_WORKDIR=$2
JENKINS_DL_DIR=$JENKINS_PERSISTENT_WORKDIR/shared-downloads
JENKINS_SSTATE_DIR=$JENKINS_PERSISTENT_WORKDIR/$MACHINE/sstate
MAXBUILDS=2
ENABLE_TESTS=${ENABLE_TESTS:=false}

# Sanity checks
if [ "$#" -ne 2 ]; then
    echo "Usage: jenkins_build.sh <MACHINE> <JENKINS_PERSISTENT_WORKDIR>"
    exit 1
fi
if [ -z "$BUILD_NUMBER" ] || [ -z "$WORKSPACE" ] || [ -z "$sourceBranch" ] || [ -z "$metaResinBranch" ] || [ -z "$supervisorTag" ]; then
    echo "[ERROR] BUILD_NUMBER, WORKSPACE, sourceBranch, metaResinBranch and supervisorTag are required."
    exit 1
fi

if [ "$buildFlavor" == "managed-dev" ]; then
	BARYS_ARGUMENTS_VAR="$BARYS_ARGUMENTS_VAR --debug-image"
	DEVELOPMENT_IMAGE=yes
	RESIN_MANAGED_IMAGE=yes
elif [ "$buildFlavor" == "managed-prod" ]; then
	DEVELOPMENT_IMAGE=no
	RESIN_MANAGED_IMAGE=yes
fi

# When supervisorTag is provided, you the appropiate barys argument
if [ "$supervisorTag" != "__ignore__" ]; then
    BARYS_ARGUMENTS_VAR="$BARYS_ARGUMENTS_VAR --supervisor-tag $supervisorTag"
fi

# Checkout meta-resin
if [ "$metaResinBranch" == "__ignore__" ]; then
    echo "[INFO] Using the default meta-resin revision (as configured in submodules)."
else
    echo "[INFO] Using special meta-resin revision from build params."
    pushd $WORKSPACE/layers/meta-resin > /dev/null 2>&1
    git config --add remote.origin.fetch '+refs/pull/*:refs/remotes/origin/pr/*'
    git fetch --all
    git checkout --force origin/$metaResinBranch
    popd > /dev/null 2>&1
fi

# Make sure shared directories are in place
mkdir -p $JENKINS_DL_DIR
mkdir -p $JENKINS_SSTATE_DIR

# Run build
docker stop $BUILD_CONTAINER_NAME 2> /dev/null || true
docker rm --volumes $BUILD_CONTAINER_NAME 2> /dev/null || true
docker run --rm \
    -v $WORKSPACE:/yocto/resin-board \
    -v $JENKINS_DL_DIR:/yocto/shared-downloads \
    -v $JENKINS_SSTATE_DIR:/yocto/shared-sstate \
    -e BUILDER_UID=$(id -u) \
    -e BUILDER_GID=$(id -g) \
    --name $BUILD_CONTAINER_NAME \
    --privileged \
    resin/yocto-build-env \
    /prepare-and-start.sh \
        --log \
        --remove-build \
        --machine "$MACHINE" \
        ${BARYS_ARGUMENTS_VAR} \
        --shared-downloads /yocto/shared-downloads \
        --shared-sstate /yocto/shared-sstate \
        --rm-work


if [ "$ENABLE_TESTS" = true ];
then
	# Run the test script in the device specific repository
	if [ -f $WORKSPACE/tests/start.sh ];
	then
		echo "Custom test file exists - Beginning test"
		/bin/bash $WORKSPACE/tests/start.sh
	else
		echo "No custom test file exists - Continuing ahead"
	fi
fi

# Artifacts
YOCTO_BUILD_DEPLOY="$WORKSPACE/build/tmp/deploy/images/$MACHINE"
VERSION_HOSTOS=$(cat "$YOCTO_BUILD_DEPLOY/VERSION_HOSTOS")
DEVICE_TYPE_JSON="$WORKSPACE/$MACHINE.json"
SLUG=$(jq --raw-output '.slug' $DEVICE_TYPE_JSON)

# Jenkins artifacts
echo "[INFO] Starting creating jenkins artifacts..."
deploy_build "$WORKSPACE/deploy-jenkins" "true"

# Deploy
if [ "$deploy" == "yes" ]; then
	echo "[INFO] Starting deployment..."
	if [ "$deployTo" == "production" ] && [ "$DEVELOPMENT_IMAGE" == "no" ]; then
		echo "[INFO] Pushing resinhup package to dockerhub and registry.resinstaging.io."
		DOCKER_REPO="resin/resinos"
		RESINREG_REPO="registry.resinstaging.io/resin/resinos"
		# Make sure the tags are valid
		# https://github.com/docker/docker/blob/master/vendor/github.com/docker/distribution/reference/regexp.go#L37
		DOCKER_TAG="$(echo $VERSION_HOSTOS-$SLUG | sed 's/[^a-z0-9A-Z_.-]/_/g')"
		RESINREG_TAG="$(echo $VERSION_HOSTOS-$SLUG | sed 's/[^a-z0-9A-Z_.-]/_/g')"
		RESINHUP_PATH=$(readlink --canonicalize $WORKSPACE/build/tmp/deploy/images/$MACHINE/resin-image-$MACHINE.resinhup-tar)
		if [ -f $RESINHUP_PATH ]; then
			docker import $RESINHUP_PATH $DOCKER_REPO:$DOCKER_TAG
			docker push $DOCKER_REPO:$DOCKER_TAG
			docker rmi $DOCKER_REPO:$DOCKER_TAG # cleanup
			docker import $RESINHUP_PATH $RESINREG_REPO:$RESINREG_TAG
			docker push $RESINREG_REPO:$RESINREG_TAG
			docker rmi $RESINREG_REPO:$RESINREG_TAG # cleanup
		else
			echo "[ERROR] The build didn't produce a resinhup package."
			exit 1
		fi
	fi

	# Deployment to s3
	S3_VERSION_HOSTOS=$VERSION_HOSTOS
	if [ "$DEVELOPMENT_IMAGE" == "yes" ]; then
		S3_VERSION_HOSTOS=$VERSION_HOSTOS.dev
	fi
	S3_DEPLOY_DIR="$WORKSPACE/deploy-s3"
	S3_DEPLOY_IMAGES_DIR="$S3_DEPLOY_DIR/$SLUG/$S3_VERSION_HOSTOS"
	deploy_build "$S3_DEPLOY_IMAGES_DIR" "false"
	if [ "$deployTo" == "production" ]; then
		S3_ACCESS_KEY=${PRODUCTION_S3_ACCESS_KEY}
		S3_SECRET_KEY=${PRODUCTION_S3_SECRET_KEY}
		if [ "$RESIN_MANAGED_IMAGE" == "yes" ]; then
			S3_BUCKET=resin-production-img-cloudformation/images
		else
			S3_BUCKET=resin-production-img-cloudformation/resinos
		fi
		S3_SYNC_OPTS="$S3_SYNC_OPTS --skip-existing"
	elif [ "$deployTo" == "staging" ]; then
		S3_ACCESS_KEY=${STAGING_S3_ACCESS_KEY}
		S3_SECRET_KEY=${STAGING_S3_SECRET_KEY}
		if [ "$RESIN_MANAGED_IMAGE" == "yes" ]; then
			S3_BUCKET=resin-staging-img/images
		else
			S3_BUCKET=resin-staging-img/resinos
		fi
	else
		echo "[ERROR] Refusing to deploy to anything other than production or master."
		exit 1
	fi
	S3_CMD="s3cmd --access_key=${S3_ACCESS_KEY} --secret_key=${S3_SECRET_KEY}"
	S3_SYNC_OPTS="--recursive --acl-public"
	docker run \
		-e BASE_DIR=/host/images \
		-e S3_CMD="$S3_CMD" \
		-e S3_SYNC_OPTS="$S3_SYNC_OPTS" \
		-e S3_BUCKET="$S3_BUCKET" \
		-e SLUG="$SLUG" \
		-e BUILD_VERSION="$S3_VERSION_HOSTOS" \
		-e DEVELOPMENT_IMAGE="$DEVELOPMENT_IMAGE" \
		-v $S3_DEPLOY_DIR:/host/images resin/resin-img:master /bin/sh -x -c ' \
		([ "${DEVELOPMENT_IMAGE}" = "no" ] && echo "${BUILD_VERSION}" > "/host/images/${SLUG}/latest" && $S3_CMD put /host/images/${SLUG}/latest s3://${S3_BUCKET}/${SLUG}/ || true) \
		&& /usr/src/app/node_modules/.bin/coffee /usr/src/app/scripts/prepare.coffee \
		&& apt-get -y update \
		&& apt-get install -y s3cmd \
		&& ([ -z "$($S3_CMD ls s3://${S3_BUCKET}/${SLUG}/${BUILD_VERSION}/)" ] \
		&& $S3_CMD $S3_SYNC_OPTS sync /host/images/${SLUG}/${BUILD_VERSION}/ s3://${S3_BUCKET}/${SLUG}/${BUILD_VERSION}/)'
fi

# Cleanup
# Keep this after writing all artifacts
rm -rf $WORKSPACE/build
