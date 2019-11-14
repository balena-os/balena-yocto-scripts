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
	\t\t --meta-balena-branch\n\
	\t\t\t (optional) The meta-balena branch to checkout before building.\n\
\t\t\t\t Default value is __ignore__ which means it builds the meta-balena revision as configured in the git submodule.\n
	\t\t --supervisor-tag\n\
	\t\t\t (optional) The resin supervisor tag specifying which supervisor version is to be included in the build.\n\
\t\t\t\t Default value is __ignore__ which means use the supervisor version already included in the meta-balena submodule.\n
	\t\t --preserve-build\n\
	\t\t\t (optional) Do not delete existing build directory.\n\
\t\t\t\t Default is to delete the existing build directory.\n
	\t\t --preserve-container\n\
	\t\t\t (optional) Do not delete the yocto build docker container when it exits.\n\
\t\t\t\t Default is to delete the container where the yocto build is taking place when this container exits.\n
	\t\t --esr\n\
	\t\t\t (optional) Is this an ESR build\n\
\t\t\t\t Defaults to false.\n"
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
	local _image=$(jq --raw-output '.yocto.image' $DEVICE_TYPE_JSON)
	local _deploy_flasher_artifact=$(jq --raw-output '.yocto.deployFlasherArtifact // empty' $DEVICE_TYPE_JSON)
	local _compressed=$(jq --raw-output '.yocto.compressed' $DEVICE_TYPE_JSON)
	local _archive=$(jq --raw-output '.yocto.archive' $DEVICE_TYPE_JSON)

	rm -rf "$_deploy_dir"
	mkdir -p "$_deploy_dir/image"

	cp -v "$DEVICE_TYPE_JSON" "$_deploy_dir/device-type.json"
	if [ "$DEVICE_STATE" = "DISCONTINUED" ]; then
	       echo "$SLUG is discontinued so only device-type.json will be deployed as build artifact."
	       return
	fi

	cp -v "$YOCTO_BUILD_DEPLOY/VERSION" "$_deploy_dir"
	cp -v "$YOCTO_BUILD_DEPLOY/VERSION_HOSTOS" "$_deploy_dir"
	cp -v $(readlink --canonicalize "$YOCTO_BUILD_DEPLOY/$_image-$MACHINE.manifest") "$_deploy_dir/$_image-$MACHINE.manifest"
	cp -v $(readlink --canonicalize "$YOCTO_BUILD_DEPLOY/resin-image-$MACHINE.docker") "$_deploy_dir/resin-image.docker"

	test "$SLUG" = "edge" && return

	if [ "$_deploy_artifact" = "docker-image" ]; then
		echo "[WARN] No artifacts to deploy. The images will be pushed to docker registry."
		return
	fi

	cp -v "$YOCTO_BUILD_DEPLOY/kernel_modules_headers.tar.gz" "$_deploy_dir" || true
	cp -v "$YOCTO_BUILD_DEPLOY/kernel_source.tar.gz" "$_deploy_dir" || true
	cp -v "$MACHINE.svg" "$_deploy_dir/logo.svg"
	if [ "${_compressed}" != 'true' ]; then
		# uncompressed, just copy and we're done
		cp -v $(readlink --canonicalize "$YOCTO_BUILD_DEPLOY/$_deploy_artifact") "$_deploy_dir/image/balena.img"
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
		cp -v $(readlink --canonicalize "$YOCTO_BUILD_DEPLOY/$_deploy_artifact") "$_deploy_dir/image/balena.img"
		(cd "$_deploy_dir/image" && zip balena.img.zip balena.img)
		if [ -n "$_deploy_flasher_artifact" ]; then
			cp -v $(readlink --canonicalize "$YOCTO_BUILD_DEPLOY/$_deploy_flasher_artifact") "$_deploy_dir/image/resin-flasher.img"
			(cd "$_deploy_dir/image" && zip resin-flasher.img.zip resin-flasher.img)
		fi
		if [ "$_remove_compressed_file" = "true" ]; then
			rm -rf $_deploy_dir/image/balena.img
			rm -rf $_deploy_dir/image/resin-flasher.img
		fi
	fi
}

rootdir="$( cd "$( dirname "$0" )" && pwd )/../../"
WORKSPACE=${WORKSPACE:-$rootdir}
ENABLE_TESTS=${ENABLE_TESTS:=false}
ESR=${ESR:-false}
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
		--meta-balena-branch)
			if [ -z "$2" ]; then
				echo "--meta-balena-branch argument needs a meta-balena branch name (if this option is not used, the default value is __ignore__)"
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
		--esr)
			ESR="true"
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

if [ "$buildFlavor" = "dev" ]; then
	BARYS_ARGUMENTS_VAR="$BARYS_ARGUMENTS_VAR --development-image"
	DEVELOPMENT_IMAGE=yes
elif [ "$buildFlavor" = "prod" ]; then
	DEVELOPMENT_IMAGE=no
else
	echo "[ERROR] No such build flavor: $buildFlavor."
	exit 1
fi

# When supervisorTag is provided, you the appropiate barys argument
if [ "$supervisorTag" != "__ignore__" ]; then
	BARYS_ARGUMENTS_VAR="$BARYS_ARGUMENTS_VAR --supervisor-tag $supervisorTag"
fi

# Checkout meta-balena
if [ "$metaResinBranch" = "__ignore__" ]; then
	echo "[INFO] Using the default meta-balena revision (as configured in submodules)."
else
	echo "[INFO] Using special meta-balena revision from build params."
	pushd $WORKSPACE/layers/meta-balena > /dev/null 2>&1
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
docker pull resin/yocto-build-env
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
        --skip-discontinued \
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
DEVICE_TYPE_JSON="$WORKSPACE/$MACHINE.json"
SLUG=$(jq --raw-output '.slug' $DEVICE_TYPE_JSON)
DEPLOY_ARTIFACT=$(jq --raw-output '.yocto.deployArtifact' $DEVICE_TYPE_JSON)
DEVICE_STATE=$(jq --raw-output '.state' "$DEVICE_TYPE_JSON")
META_BALENA_VERSION=$(cat layers/meta-balena/meta-balena-common/conf/distro/include/balena-os.inc | grep -m 1 DISTRO_VERSION | cut -d ' ' -f3)
if [ "$DEVICE_STATE" != "DISCONTINUED" ]; then
	VERSION_HOSTOS=$(cat "$YOCTO_BUILD_DEPLOY/VERSION_HOSTOS")
else
	VERSION_HOSTOS=$(cat "$WORKSPACE/VERSION")
fi

# Jenkins artifacts
echo "[INFO] Starting creating jenkins artifacts..."
deploy_build "$WORKSPACE/deploy-jenkins" "true"

deploy_images () {
	local _docker_repo
	local _variant=""
	if [ "$deployTo" = "production" ]; then
		_docker_repo="resin/resinos"
	else
		_docker_repo="resin/resinos-staging"
	fi
	if [ "$DEVELOPMENT_IMAGE" = "yes" ]; then
		_variant=".dev"
	fi
	# Make sure the tags are valid
	# https://github.com/docker/docker/blob/master/vendor/github.com/docker/distribution/reference/regexp.go#L37
	local _tag="$(echo $VERSION_HOSTOS$_variant-$SLUG | sed 's/[^a-z0-9A-Z_.-]/_/g')"
	local _exported_image_path=$(readlink --canonicalize $WORKSPACE/build/tmp/deploy/images/$MACHINE/resin-image-$MACHINE.docker)

	echo "[INFO] Pushing image to dockerhub $_docker_repo:$_tag..."

	if [ ! -f $_exported_image_path ]; then
		echo "[ERROR] The build didn't produce a valid image."
		exit 1
	fi

	local _hostapp_image=$(docker load --quiet -i "$_exported_image_path" | cut -d: -f1 --complement | tr -d ' ')
	docker tag "$_hostapp_image" "$_docker_repo:$_tag"

	docker push $_docker_repo:$_tag
	deploy_to_balena $_exported_image_path

	docker rmi -f "$_hostapp_image"
}

deploy_to_balena() {
	local _exported_image_path=$1
	docker pull resin/balena-push-env
	docker run --rm -t \
		-e BASE_DIR=/host \
		-e BALENAOS_STAGING_TOKEN=$BALENAOS_STAGING_TOKEN \
		-e BALENAOS_PRODUCTION_TOKEN=$BALENAOS_PRODUCTION_TOKEN \
		-e SLUG=$SLUG \
		-e DEVELOPMENT_IMAGE=$DEVELOPMENT_IMAGE \
		-e DEPLOY_TO=$deployTo \
		-e VERSION_HOSTOS=$VERSION_HOSTOS \
		-e ESR=$ESR \
		-e META_BALENA_VERSION=$META_BALENA_VERSION \
		-v $_exported_image_path:/host/resin-image.docker \
		--privileged \
		resin/balena-push-env /start-docker-and-push.sh
}

deploy_to_s3() {
	local _s3_bucket=$1
	local _s3_version_hostos=$VERSION_HOSTOS
	if [ "$DEVELOPMENT_IMAGE" = "yes" ]; then
		_s3_version_hostos=$_s3_version_hostos.dev
	else
		_s3_version_hostos=$_s3_version_hostos.prod
	fi
	local _s3_deploy_dir="$WORKSPACE/deploy-s3"
	local _s3_deploy_images_dir="$_s3_deploy_dir/$SLUG/$_s3_version_hostos"

	deploy_build "$_s3_deploy_images_dir" "false"

	local _s3_access_key _s3_secret_key
	if [ "$deployTo" = "production" ]; then
		_s3_access_key=${PRODUCTION_S3_ACCESS_KEY}
		_s3_secret_key=${PRODUCTION_S3_SECRET_KEY}
	elif [ "$deployTo" = "staging" ]; then
		_s3_access_key=${STAGING_S3_ACCESS_KEY}
		_s3_secret_key=${STAGING_S3_SECRET_KEY}
	else
		echo "[ERROR] Refusing to deploy to anything other than production or master."
		exit 1
	fi

	local _s3_cmd="s4cmd --access-key=${_s3_access_key} --secret-key=${_s3_secret_key}"
	local _s3_sync_opts="--recursive --API-ACL=public-read"
	docker pull resin/resin-img:master
	docker run --rm -t \
		-e BASE_DIR=/host/images \
		-e S3_CMD="$_s3_cmd" \
		-e S3_SYNC_OPTS="$_s3_sync_opts" \
		-e S3_BUCKET="$_s3_bucket" \
		-e SLUG="$SLUG" \
		-e DEPLOY_ARTIFACT="$DEPLOY_ARTIFACT" \
		-e BUILD_VERSION="$_s3_version_hostos" \
		-e DEVELOPMENT_IMAGE="$DEVELOPMENT_IMAGE" \
		-e DEPLOYER_UID=$(id -u) \
		-e DEPLOYER_GID=$(id -g) \
		-e DEVICE_STATE="$DEVICE_STATE" \
		-v $_s3_deploy_dir:/host/images resin/resin-img:master /bin/sh -x -e -c ' \
			apt-get -y update
			apt-get install -y s4cmd
			echo "Creating and setting deployer user $DEPLOYER_UID:$DEPLOYER_GID."
			groupadd -g $DEPLOYER_GID deployer
			useradd -m -u $DEPLOYER_UID -g $DEPLOYER_GID deployer
			su deployer<<EOSU
set -ex
echo "${BUILD_VERSION}" > "/host/images/${SLUG}/latest"
if [ "$DEPLOY_ARTIFACT" = "docker-image" ] || [ "$DEVICE_STATE" = "DISCONTINUED" ]; then
	echo "WARNING: No raw image prepare step for docker images only artifacts or discontinued device types."
else
	/usr/src/app/node_modules/.bin/ts-node /usr/src/app/scripts/prepare.ts
fi
if [ -z "$($S3_CMD ls s3://${S3_BUCKET}/${SLUG}/${BUILD_VERSION}/)" ] || [ -n "$($S3_CMD ls s3://${S3_BUCKET}/${SLUG}/${BUILD_VERSION}/IGNORE)" ]; then
	touch /host/images/${SLUG}/${BUILD_VERSION}/IGNORE
	$S3_CMD del -rf s3://${S3_BUCKET}/${SLUG}/${BUILD_VERSION}
	$S3_CMD put /host/images/${SLUG}/${BUILD_VERSION}/IGNORE s3://${S3_BUCKET}/${SLUG}/${BUILD_VERSION}/
	$S3_CMD $S3_SYNC_OPTS dsync /host/images/${SLUG}/${BUILD_VERSION}/ s3://${S3_BUCKET}/${SLUG}/${BUILD_VERSION}/
	if [ "${DEVELOPMENT_IMAGE}" = "no" ]; then
		$S3_CMD put /host/images/${SLUG}/latest s3://${S3_BUCKET}/${SLUG}/ --API-ACL=public-read -f
	fi
	$S3_CMD del s3://${S3_BUCKET}/${SLUG}/${BUILD_VERSION}/IGNORE
else
	echo "WARNING: Deployment already done for ${SLUG} at version ${BUILD_VERSION}"
fi
EOSU
		'

}

# Deploy

if [ "$deploy" = "yes" ]; then
	echo "[INFO] Starting deployment..."
	if [ "$DEVICE_STATE" != "DISCONTINUED" ]; then
		deploy_images
	fi

	if [ "$deployTo" = "production" ]; then
		S3_BUCKET_PREFIX="resin-production-img-cloudformation"

		if [ "${ESR}" =  "true" ]; then
			S3_BUCKET_SUFFIX_RESINIO="esr-images"
			S3_BUCKET_SUFFIX_RESINOS="esr-resinos"
		else
			S3_BUCKET_SUFFIX_RESINIO="images"
			S3_BUCKET_SUFFIX_RESINOS="resinos"
		fi
		S3_BUCKET_RESINIO="${S3_BUCKET_PREFIX}/${S3_BUCKET_SUFFIX_RESINIO}"
		S3_BUCKET_RESINOS="${S3_BUCKET_PREFIX}/${S3_BUCKET_SUFFIX_RESINOS}"

	elif [ "$deployTo" = "staging" ]; then
		S3_BUCKET_PREFIX="resin-staging-img"

		if [ "${ESR}" =  "true" ]; then
			S3_BUCKET_SUFFIX_RESINIO="esr-images"
			S3_BUCKET_SUFFIX_RESINOS="esr-resinos"
		else
			S3_BUCKET_SUFFIX_RESINIO="images"
			S3_BUCKET_SUFFIX_RESINOS="resinos"
		fi
		S3_BUCKET_RESINIO="${S3_BUCKET_PREFIX}/${S3_BUCKET_SUFFIX_RESINIO}"
		S3_BUCKET_RESINOS="${S3_BUCKET_PREFIX}/${S3_BUCKET_SUFFIX_RESINOS}"
	fi

	deploy_to_s3 "$S3_BUCKET_RESINIO"
	deploy_to_s3 "$S3_BUCKET_RESINOS"
fi

# Cleanup
# Keep this after writing all artifacts
rm -rf $WORKSPACE/build
