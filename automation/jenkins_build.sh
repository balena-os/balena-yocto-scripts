#!/bin/bash

[ "${VERBOSE}" = "verbose" ] && set -x
set -e

NAMESPACE=${NAMESPACE:-resin}

print_help() {
	echo -e "Script options:\n\
	\t\t -h | --help\n
	\t\t -m | --machine\n\
	\t\t\t (mandatory) Machine to build for. This is a mandatory argument\n
	\t\t --shared-dir\n\
	\t\t\t (mandatory) Directory where to store shared downloads and shared sstate.\n
	\t\t -b | --build-flavor\n\
	\t\t\t (mandatory) The build flavor. (prod | dev)\n
	\t\t -a | --additional-variable\n\
	\t\t\t (optional) Inject additional local.conf variables. The format of the arguments needs to be VARIABLE=VALUE.\n\
	\t\t --meta-balena-branch\n\
	\t\t\t (optional) The meta-balena branch to checkout before building.\n\
\t\t\t\t Default value is __ignore__ which means it builds the meta-balena revision as configured in the git submodule.\n
	\t\t --supervisor-version\n\
	\t\t\t (optional) The balena supervisor release version to be included in the build.\n\
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

automation_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source "${automation_dir}/include/balena-lib.inc"
source "${automation_dir}/include/balena-deploy.inc"

rootdir="$( cd "$( dirname "$0" )" && pwd )/../../"
WORKSPACE=${WORKSPACE:-$rootdir}
ENABLE_TESTS=${ENABLE_TESTS:=false}
ESR=${ESR:-false}
AMI=${AMI:-false}
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
			metaBalenaBranch="${metaBalenaBranch:-$2}"
			;;
		--supervisor-version)
			if [ -z "$2" ]; then
				echo "--supervisor-version argument needs a balena supervisor release version (if this option is not used, the default value is __ignore__)"
				exit 1
			fi
			supervisorVersion="${supervisorVersion:-$2}"
			;;
		--esr)
			ESR="true"
			;;
		--preserve-build)
			PRESERVE_BUILD=1
			BARYS_ARGUMENTS_VAR=${BARYS_ARGUMENTS_VAR//--remove-build/}
			;;
		--preserve-container)
			REMOVE_CONTAINER=""
			;;
		--ami)
			AMI="true"
			;;
	esac
	shift
done

metaBalenaBranch=${metaBalenaBranch:-__ignore__}
supervisorVersion=${supervisorVersion:-__ignore__}

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
elif [ "$buildFlavor" = "prod" ]; then
	:
else
	echo "[ERROR] No such build flavor: $buildFlavor."
	exit 1
fi

# When supervisorVersion is provided, set the appropiate barys argument
if [ "$supervisorVersion" != "__ignore__" ]; then
	BARYS_ARGUMENTS_VAR="$BARYS_ARGUMENTS_VAR --supervisor-version $supervisorVersion"
fi

# Checkout meta-balena
if [ "$metaBalenaBranch" = "__ignore__" ]; then
	echo "[INFO] Using the default meta-balena revision (as configured in submodules)."
else
	echo "[INFO] Using special meta-balena revision from build params."
	pushd $WORKSPACE/layers/meta-balena > /dev/null 2>&1
	git config --add remote.origin.fetch '+refs/pull/*:refs/remotes/origin/pr/*'
	git fetch --all
	git checkout --force $metaBalenaBranch
	popd > /dev/null 2>&1
fi

"${automation_dir}"/../build/balena-build.sh -d "${MACHINE}" -s "${JENKINS_PERSISTENT_WORKDIR}" -a "$(balena_lib_environment)" -v "${buildFlavor}" -g "${BARYS_ARGUMENTS_VAR}"

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
DEVICE_STATE=$(balena_lib_get_dt_state "${MACHINE}")
if [ "$DEVICE_STATE" != "DISCONTINUED" ]; then
	VERSION_HOSTOS=$(balena_lib_get_os_version)
else
	VERSION_HOSTOS=$(cat "$WORKSPACE/VERSION")
fi

PRIVATE_DT=$(balena_api_is_dt_private "${MACHINE}")

# Jenkins artifacts
echo "[INFO] Starting creating jenkins artifacts..."
balena_deploy_artifacts "${MACHINE}" "$WORKSPACE/deploy-jenkins" "true"

# Deploy
if [ "$deploy" = "yes" ]; then
	echo "[INFO] Starting deployment..."

	balena_deploy_to_s3 "$MACHINE" "${buildFlavor}" "${ESR}" "${deployTo}"

	if [ "${_state}" != "DISCONTINUED" ]; then
		balena_deploy_to_dockerhub "${MACHINE}"
		balena_deploy_hostapp "${MACHINE}"
	fi

fi

if [ "$AMI" = "true" ]; then
	echo "[INFO] Generating AMI"
	"${automation_dir}"/jenkins_generate_ami.sh
fi

# Cleanup
# Keep this after writing all artifacts
rm -rf $WORKSPACE/build
