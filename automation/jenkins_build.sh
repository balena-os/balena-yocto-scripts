#!/bin/bash

set -ex

BUILD_CONTAINER_NAME=yocto-build-$$

print_help() {
	echo -e "Script options:\n\
	\t\t -h | --help\n
	\t\t -m | --machine\n\
	\t\t\t (mandatory) Machine to build for. This is a mandatory argument\n
	\t\t --shared-dir\n\
	\t\t\t (mandatory) Directory where to store shared downloads and shared sstate.\n
	\t\t -b | --build-flavor\n\
	\t\t\t (mandatory) The build flavor. Can be one of the following: managed-dev, managed-prod, unmanaged-dev, unmanaged-prod\n
	\t\t --meta-resin-branch\n\
	\t\t\t (optional) The meta-resin branch to checkout before building.\n\
\t\t\t\t Default value is __ignore__ which means it builds the meta-resin revision as configured in the git submodule.\n
	\t\t --supervisor-tag\n\
	\t\t\t (optional) The resin supervisor tag specifying which supervisor version is to be included in the build.\n\
\t\t\t\t Default value is __ignore__ which means use the supervisor version already included in the meta-resin submodule.\n
	\t\t --preserve-build\n\
	\t\t\t (optional) Do not delete existing build directory.\n\
\t\t\t\t Default is to delete the existing build directory.\n
	\t\t --preserve-container\n\
	\t\t\t (optional) Do not delete the yocto build docker container when it exits.\n\
\t\t\t\t Default is to delete the container where the yocto build is taking place when this container exits.\n"
}

cleanup() {
	echo "[INFO] $0: Cleanup."

	# Stop docker container
	echo "[INFO] $0: Cleaning up yocto-build container."
	docker stop $BUILD_CONTAINER_NAME 2> /dev/null || true
	docker rm --volumes $BUILD_CONTAINER_NAME 2> /dev/null || true

	if [ "$1" = "fail" ]; then
		exit 1
	fi
}
trap 'cleanup fail' SIGINT SIGTERM

deploy_build () {
	local _deploy_dir="$1"
	local _remove_compressed_file="$2"

	local _deploy_artifact=$(jq --raw-output '.yocto.deployArtifact' $DEVICE_TYPE_JSON)
	local _deploy_flasher_artifact=$(jq --raw-output '.yocto.deployFlasherArtifact // empty' $DEVICE_TYPE_JSON)
	local _compressed=$(jq --raw-output '.yocto.compressed' $DEVICE_TYPE_JSON)
	local _archive=$(jq --raw-output '.yocto.archive' $DEVICE_TYPE_JSON)

	rm -rf "$_deploy_dir"
	mkdir -p "$_deploy_dir/image"

	cp -v "$YOCTO_BUILD_DEPLOY/VERSION" "$_deploy_dir"
	cp -v "$YOCTO_BUILD_DEPLOY/VERSION_HOSTOS" "$_deploy_dir"
	cp -v "$DEVICE_TYPE_JSON" "$_deploy_dir/device-type.json"

	test "$SLUG" = "edge" && return

	cp -v "$YOCTO_BUILD_DEPLOY/kernel_modules_headers.tar.gz" "$_deploy_dir"
	if [ "${_compressed}" != 'true' ]; then
		# uncompressed, just copy and we're done
		cp -v $(readlink --canonicalize "$YOCTO_BUILD_DEPLOY/$_deploy_artifact") "$_deploy_dir/image/resin.img"
		if [ -n "$_deploy_flasher_artifact" ]; then
			cp -v $(readlink --canonicalize "$YOCTO_BUILD_DEPLOY/$_deploy_flasher_artifact") "$_deploy_dir/image/resin-flasher.img"
		fi
		return
	fi

	if [ "${_archive}" = 'true' ]; then
		cp -rv "$YOCTO_BUILD_DEPLOY"/"$_deploy_artifact"/* "$_deploy_dir"/image/
		(cd "$_deploy_dir/image/" && zip -r "../$_deploy_artifact.zip" .)
		if [ -n "$_deploy_flasher_artifact" ]; then
		    cp -rv "$YOCTO_BUILD_DEPLOY"/"$_deploy_flasher_artifact"/* "$_deploy_dir"/image/
		    (cd "$_deploy_dir/image/" && zip -r "../$_deploy_flasher_artifact.zip" .)
		fi
		if [ "$_remove_compressed_file" = "true" ]; then
			rm -rf $_deploy_dir/image
		fi
	else
		cp -v $(readlink --canonicalize "$YOCTO_BUILD_DEPLOY/$_deploy_artifact") "$_deploy_dir/image/resin.img"
		(cd "$_deploy_dir/image" && zip resin.img.zip resin.img)
		if [ -n "$_deploy_flasher_artifact" ]; then
			cp -v $(readlink --canonicalize "$YOCTO_BUILD_DEPLOY/$_deploy_flasher_artifact") "$_deploy_dir/image/resin-flasher.img"
			(cd "$_deploy_dir/image" && zip resin-flasher.img.zip resin-flasher.img)
		fi
		if [ "$_remove_compressed_file" = "true" ]; then
			rm -rf $_deploy_dir/image/resin.img
			rm -rf $_deploy_dir/image/resin-flasher.img
		fi
	fi
}

rootdir="$( cd "$( dirname "$0" )" && pwd )/../../"
WORKSPACE=${WORKSPACE:-$rootdir}
ENABLE_TESTS=${ENABLE_TESTS:=false}
BARYS_ARGUMENTS_VAR="--remove-build"
REMOVE_CONTAINER="--rm"

# process script arguments
args_number="$#"
while [[ $# -ge 1 ]]; do
	arg=$1
	case $arg in
		-h|--help)
			print_help
			exit 0
			;;
		-m|--machine)
			if [ -z "$2" ]; then
				echo "-m|--machine argument needs a machine name"
				exit 1
			fi
			MACHINE="$2"
			;;
		--shared-dir)
			if [ -z "$2" ]; then
				echo "--shared-dir needs directory name where to store shared downloads and sstate data"
				exit 1
			fi
			JENKINS_PERSISTENT_WORKDIR="$2"
			;;
		-b|--build-flavor)
			if [ -z "$2" ]; then
				echo "-b|--build-flavor argument needs a build type"
				exit 1
			fi
			buildFlavor="${buildFlavor:-$2}"
			;;
		--meta-resin-branch)
			if [ -z "$2" ]; then
				echo "--meta-resin-branch argument needs a meta-resin branch name (if this option is not used, the default value is __ignore__)"
				exit 1
			fi
			metaResinBranch="${metaResinBranch:-$2}"
			;;
		--supervisor-tag)
			if [ -z "$2" ]; then
				echo "--supervisor-tag argument needs a resin supervisor tag name (if this option is not used, the default value is __ignore__)"
				exit 1
			fi
			supervisorTag="${supervisorTag:-$2}"
			;;
		--preserve-build)
			BARYS_ARGUMENTS_VAR=""
			;;
		--preserve-container)
			REMOVE_CONTAINER=""
			;;
	esac
	shift
done

JENKINS_DL_DIR=$JENKINS_PERSISTENT_WORKDIR/shared-downloads
JENKINS_SSTATE_DIR=$JENKINS_PERSISTENT_WORKDIR/$MACHINE/sstate
metaResinBranch=${metaResinBranch:-__ignore__}
supervisorTag=${supervisorTag:-__ignore__}

# Sanity checks
if [ -z "$MACHINE" ] || [ -z "$JENKINS_PERSISTENT_WORKDIR" ] || [ -z "$buildFlavor" ]; then
	echo -e "\n[ERROR] You are missing one of these arguments:\n
\t -m <MACHINE>\n
\t --shared-dir <PERSISTENT_WORKDIR>\n
\t --build-flavor <BUILD_FLAVOR_TYPE>\n\n
Run with -h or --help for a complete list of arguments.\n"
	exit 1
fi

if [ "$buildFlavor" = "managed-dev" ]; then
	BARYS_ARGUMENTS_VAR="$BARYS_ARGUMENTS_VAR --resinio"
	BARYS_ARGUMENTS_VAR="$BARYS_ARGUMENTS_VAR --development-image"
	DEVELOPMENT_IMAGE=yes
	RESIN_MANAGED_IMAGE=yes
elif [ "$buildFlavor" = "managed-prod" ]; then
	BARYS_ARGUMENTS_VAR="$BARYS_ARGUMENTS_VAR --resinio"
	DEVELOPMENT_IMAGE=no
	RESIN_MANAGED_IMAGE=yes
elif [ "$buildFlavor" = "unmanaged-dev" ]; then
	BARYS_ARGUMENTS_VAR="$BARYS_ARGUMENTS_VAR --development-image"
	DEVELOPMENT_IMAGE=yes
	RESIN_MANAGED_IMAGE=no
elif [ "$buildFlavor" = "unmanaged-prod" ]; then
	DEVELOPMENT_IMAGE=no
	RESIN_MANAGED_IMAGE=no
fi

# When supervisorTag is provided, you the appropiate barys argument
if [ "$supervisorTag" != "__ignore__" ]; then
	BARYS_ARGUMENTS_VAR="$BARYS_ARGUMENTS_VAR --supervisor-tag $supervisorTag"
fi

# Checkout meta-resin
if [ "$metaResinBranch" = "__ignore__" ]; then
	echo "[INFO] Using the default meta-resin revision (as configured in submodules)."
else
	echo "[INFO] Using special meta-resin revision from build params."
	pushd $WORKSPACE/layers/meta-resin > /dev/null 2>&1
	git config --add remote.origin.fetch '+refs/pull/*:refs/remotes/origin/pr/*'
	git fetch --all
	git checkout --force $metaResinBranch
	popd > /dev/null 2>&1
fi

# Make sure shared directories are in place
mkdir -p $JENKINS_DL_DIR
mkdir -p $JENKINS_SSTATE_DIR

# Run build
docker stop $BUILD_CONTAINER_NAME 2> /dev/null || true
docker rm --volumes $BUILD_CONTAINER_NAME 2> /dev/null || true
docker run ${REMOVE_CONTAINER} \
    -v $WORKSPACE:/yocto/resin-board \
    -v $JENKINS_DL_DIR:/yocto/shared-downloads \
    -v $JENKINS_SSTATE_DIR:/yocto/shared-sstate \
    -v $SSH_AUTH_SOCK:/tmp/ssh-agent \
    -e SSH_AUTH_SOCK=/tmp/ssh-agent \
    -e BUILDER_UID=$(id -u) \
    -e BUILDER_GID=$(id -g) \
    --name $BUILD_CONTAINER_NAME \
    --privileged \
    resin/yocto-build-env \
    /prepare-and-start.sh \
        --log \
        --machine "$MACHINE" \
        ${BARYS_ARGUMENTS_VAR} \
        --shared-downloads /yocto/shared-downloads \
        --shared-sstate /yocto/shared-sstate \
        --rm-work


if [ "$ENABLE_TESTS" = true ]; then
	# Run the test script in the device specific repository
	if [ -f $WORKSPACE/tests/start.sh ]; then
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

deploy_resinhup_to_registries() {
	local _docker_repo="resin/resinos"
	local _resinreg_repo="registry.resinstaging.io/resin/resinos"
	# Make sure the tags are valid
	# https://github.com/docker/docker/blob/master/vendor/github.com/docker/distribution/reference/regexp.go#L37
	local _docker_tag="$(echo $VERSION_HOSTOS-$SLUG | sed 's/[^a-z0-9A-Z_.-]/_/g')"
	local _resinreg_tag="$(echo $VERSION_HOSTOS-$SLUG | sed 's/[^a-z0-9A-Z_.-]/_/g')"
	local _resinhup_path=$(readlink --canonicalize $WORKSPACE/build/tmp/deploy/images/$MACHINE/resin-image-$MACHINE.resinhup-tar)

	echo "[INFO] Pushing resinhup package to dockerhub and registry.resinstaging.io."

	if [ ! -f $_resinhup_path ]; then
		echo "[ERROR] The build didn't produce a resinhup package."
		exit 1
	fi

	docker import $_resinhup_path $_docker_repo:$_docker_tag
	docker push $_docker_repo:$_docker_tag
	docker rmi $_docker_repo:$_docker_tag # cleanup

	docker import $_resinhup_path $_resinreg_repo:$_resinreg_tag
	docker push $_resinreg_repo:$_resinreg_tag
	docker rmi $_resinreg_repo:$_resinreg_tag # cleanup
}

deploy_to_s3() {
	local _s3_version_hostos=$VERSION_HOSTOS
	if [ "$DEVELOPMENT_IMAGE" = "yes" ]; then
		_s3_version_hostos=$_s3_version_hostos.dev
	else
		_s3_version_hostos=$_s3_version_hostos.prod
	fi
	local _s3_deploy_dir="$WORKSPACE/deploy-s3"
	local _s3_deploy_images_dir="$_s3_deploy_dir/$SLUG/$_s3_version_hostos"

	deploy_build "$_s3_deploy_images_dir" "false"

	local _s3_access_key _s3_secret_key _s3_bucket
	if [ "$deployTo" = "production" ]; then
		_s3_access_key=${PRODUCTION_S3_ACCESS_KEY}
		_s3_secret_key=${PRODUCTION_S3_SECRET_KEY}
		if [ "$RESIN_MANAGED_IMAGE" = "yes" ]; then
			_s3_bucket=resin-production-img-cloudformation/images
		else
			_s3_bucket=resin-production-img-cloudformation/resinos
		fi
		S3_SYNC_OPTS="$S3_SYNC_OPTS --skip-existing"
	elif [ "$deployTo" = "staging" ]; then
		_s3_access_key=${STAGING_S3_ACCESS_KEY}
		_s3_secret_key=${STAGING_S3_SECRET_KEY}
		if [ "$RESIN_MANAGED_IMAGE" = "yes" ]; then
			_s3_bucket=resin-staging-img/images
		else
			_s3_bucket=resin-staging-img/resinos
		fi
	else
		echo "[ERROR] Refusing to deploy to anything other than production or master."
		exit 1
	fi

	local _s3_cmd="s3cmd --access_key=${_s3_access_key} --secret_key=${_s3_secret_key}"
	local _s3_sync_opts="--recursive --acl-public"
	docker run --rm -t \
		-e BASE_DIR=/host/images \
		-e S3_CMD="$_s3_cmd" \
		-e S3_SYNC_OPTS="$_s3_sync_opts" \
		-e S3_BUCKET="$_s3_bucket" \
		-e SLUG="$SLUG" \
		-e BUILD_VERSION="$_s3_version_hostos" \
		-e DEVELOPMENT_IMAGE="$DEVELOPMENT_IMAGE" \
		-e DEPLOYER_UID=$(id -u) \
		-e DEPLOYER_GID=$(id -g) \
		-v $_s3_deploy_dir:/host/images resin/resin-img:master /bin/sh -x -e -c ' \
			apt-get -y update
			apt-get install -y s3cmd
			echo "Creating and setting deployer user $DEPLOYER_UID:$DEPLOYER_GID."
			groupadd -g $DEPLOYER_GID deployer
			useradd -m -u $DEPLOYER_UID -g $DEPLOYER_GID deployer
			su deployer<<EOSU
echo "${BUILD_VERSION}" > "/host/images/${SLUG}/latest"
/usr/src/app/node_modules/.bin/coffee /usr/src/app/scripts/prepare.coffee
if [ -z "$($S3_CMD ls s3://${S3_BUCKET}/${SLUG}/${BUILD_VERSION}/)" ] || [ -n "$($S3_CMD ls s3://${S3_BUCKET}/${SLUG}/${BUILD_VERSION}/IGNORE)" ]; then
	touch /host/images/${SLUG}/${BUILD_VERSION}/IGNORE
	$S3_CMD rm -rf s3://${S3_BUCKET}/${SLUG}/${BUILD_VERSION}
	$S3_CMD put /host/images/${SLUG}/${BUILD_VERSION}/IGNORE s3://${S3_BUCKET}/${SLUG}/${BUILD_VERSION}/
	$S3_CMD $S3_SYNC_OPTS sync /host/images/${SLUG}/${BUILD_VERSION}/ s3://${S3_BUCKET}/${SLUG}/${BUILD_VERSION}/
	if [ "${DEVELOPMENT_IMAGE}" = "no" ]; then
		$S3_CMD put /host/images/${SLUG}/latest s3://${S3_BUCKET}/${SLUG}/
	fi
	$S3_CMD rm s3://${S3_BUCKET}/${SLUG}/${BUILD_VERSION}/IGNORE
else
	echo "WARNING: Deployment already done for ${SLUG} at version ${BUILD_VERSION}"
fi
EOSU
		'

}

# Deploy
if [ "$deploy" = "yes" ]; then
	echo "[INFO] Starting deployment..."
	if [ "$deployTo" = "production" ] && [ "$DEVELOPMENT_IMAGE" = "no" ] && [ "$RESIN_MANAGED_IMAGE" = "yes" ]; then
		deploy_resinhup_to_registries
	fi

	deploy_to_s3
fi

# Cleanup
# Keep this after writing all artifacts
rm -rf $WORKSPACE/build
