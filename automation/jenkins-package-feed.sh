#!/bin/bash

set -e

script_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
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
	\t\t -t | --build-target\n\
	\t\t\t (optional) The bitbake build target. If not provided it uses barys default for the provided machine\n
	\t\t -a | --additional-variable\n\
	\t\t\t (optional) Inject additional local.conf variables. The format of the arguments needs to be VARIABLE=VALUE.\n\
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

source "${script_dir}/balena-lib.sh"

deploy_build () {
	local _deploy_dir="$1"
	if [ -e "${WORKSPACE}/build/tmp/deploy/${PACKAGE_TYPE}" ]; then
		echo "[INFO]: Deploying package feed"
		mkdir -p "$_deploy_dir/${PACKAGE_TYPE}"
		cp -r "${WORKSPACE}/build/tmp/deploy/${PACKAGE_TYPE}" "$_deploy_dir/"
		echo "${VERSION_HOSTOS}" > "$_deploy_dir/VERSION_HOSTOS"
	fi
}

rootdir="$( cd "$( dirname "$0" )" && pwd )/../../"
WORKSPACE=${WORKSPACE:-$rootdir}
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
			shift
			;;
		-a|--additional-variable)
			if [ -z "$2" ]; then
				echo "\"$1\" needs an argument in the format VARIABLE=VALUE"
				exit 1
			fi
			if echo "$2" | grep -vq '^[A-Za-z0-9_-]*='; then
				echo "\"$2\" has the wrong argument format for \"$1\". Read help."
				exit 1
			fi
			BARYS_ARGUMENTS_VAR="$BARYS_ARGUMENTS_VAR $1 $2"
			shift
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
			BARYS_ARGUMENTS_VAR=${BARYS_ARGUMENTS_VAR//--remove-build/}
			;;
		--preserve-container)
			REMOVE_CONTAINER=""
			;;
		-t|--build-target)
			if [ -z "$2" ]; then
				echo "-t|--build-target argument needs a target image name"
				exit 1
			fi
			BARYS_ARGUMENTS_VAR="$BARYS_ARGUMENTS_VAR --bitbake-target $2"
			shift
			;;
		-e|--extension)
			if [ -z "$2" ]; then
				echo "-e|--extension argument needs a target extension name"
				exit 1
			fi
			BARYS_ARGUMENTS_VAR="$BARYS_ARGUMENTS_VAR --extension $2"
			shift
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

NAMESPACE=${NAMESPACE:-resin}

# Run build
docker stop $BUILD_CONTAINER_NAME 2> /dev/null || true
docker rm --volumes $BUILD_CONTAINER_NAME 2> /dev/null || true
if ! docker_pull_helper_image "Dockerfile_yocto-build-env"; then
	exit 1
fi
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
    ${NAMESPACE}/yocto-build-env \
    /prepare-and-start.sh \
        --log \
        --machine "$MACHINE" \
        ${BARYS_ARGUMENTS_VAR} \
        --shared-downloads /yocto/shared-downloads \
        --shared-sstate /yocto/shared-sstate \
        --skip-discontinued \
        --continue \
        --rm-work

# Artifacts
YOCTO_BUILD_DEPLOY="$WORKSPACE/build/tmp/deploy/images/$MACHINE"
PACKAGE_TYPE=${PACKAGE_TYPE:-ipk}
read -r YOCTO_BUILD_${PACKAGE_TYPE} <<< "$WORKSPACE/build/tmp/deploy/${PACKAGE_TYPE}"

# If no image is build there is no version files but we still can obtain the version from os-release
if [ -z "${VERSION_HOSTOS}" ]; then
	VERSION_HOSTOS=$(grep "^VERSION=" "${YOCTO_BUILD_DEPLOY}/os-release" | cut -d "=" -f2 | tr -d \")
fi

[ -z "${VERSION_HOSTOS}" ] && echo "Unable to find OS version - please build os-release as part of your target" && exit 1

# Jenkins artifacts
echo "[INFO] Starting creating jenkins artifacts..."
deploy_build "$WORKSPACE/deploy-jenkins" "true"

# Cleanup
# Keep this after writing all artifacts
rm -rf $WORKSPACE/build
