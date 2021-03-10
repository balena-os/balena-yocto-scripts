#!/bin/bash
set -e

script_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
device_dir=$(realpath "${script_dir}/../../")
BALENA_YOCTO_SCRIPTS_REVISION=$(cd "${script_dir}" && git rev-parse --short HEAD)

# Required for fetch_image_from_app()
source "${device_dir}/layers/meta-balena/meta-balena-common/recipes-containers/docker-disk/files/balena-api.inc"
source "${script_dir}/balena-api.inc"

# Deploys to passed container image to BalenaCloud
# Input arguments:
#  $1: Path to the local image to deploy
#  $2: Balena environment
#  $3: Balena API token
#  $4: App name to deploy to (defaults to SLUG environment variable)
#  $5: ESR release flag (default to "ESR" environment variable)
#  $6: Development flag (defaults to DEVELOPMENT_IMAGE environment variable)
#
balena_deploy_hostapp() {
	local _image_path=$1
	local _api_env=$2
	local _token=$3
	local _app=$4
	local _esr=$5
	local _variant=$6
	local _version
	if ! balena_lib_docker_pull_helper_image "Dockerfile_balena-push-env" balena_yocto_scripts_revision; then
		exit 1
	fi

	[ -z "${_image_path}" ] && echo "An image is required" && return
	[ -z "${_token}" ] && echo "A Balena token is required" && return
	[ -z "${_api_env}" ] && echo "A Balena environment is required" && return

	_version=${VERSION_HOSTOS:$(balena_lib_get_os_version)}
	_app=${_app:="${MACHINE}"}
	_esr=${_esr:-"${ESR}"}
	_variant=${_variant:-"${buildFlavor}"}
	_meta_balena_version=${META_BALENA_VERSION:$(balena_lib_get_meta_balena_version)}
	NAMESPACE=${NAMESPACE:-resin}

	# shellcheck disable=SC2154
	docker run --rm -t \
		-e BASE_DIR=/host \
		-e TOKEN="${_token}" \
		-e API_ENV="${_api_env}" \
		-e APPNAME="${_app}" \
		-e VARIANT="${_variant}" \
		-e VERSION_HOSTOS="${_version}" \
		-e ESR="${_esr}" \
		-e META_BALENA_VERSION="${_meta_balena_version}" \
		-v "${_image_path}":/host/appimage.docker \
		--privileged \
		"${NAMESPACE}"/balena-push-env:"${balena_yocto_scripts_revision}" /balena-push-os-version.sh
}

# Builds and deploys the specified block to BalenaCloud
# Input arguments;
#  $1: App name to deploy into
#  $2: Device type for the app
#  $3: Package list to build the block with
#
balena_deploy_block() {
	local _appName="$1"
	local _machine="${2:-${MACHINE}}"
	local _packages="${3:-${PACKAGES}}"

	[ -z "${_appName}" ] && echo "App name is required" && return
	[ -z "${_machine}" ] && echo "Device type is required" && return
	[ -z "${_packages}" ] && echo "Package list is required" && return

	if ! balena_lib_docker_pull_helper_image "Dockerfile_yocto-block-build-env" balena_yocto_scripts_revision; then
		exit 1
	fi
	docker run --rm -t \
		-e APPNAME="${1}" \
		-e API_ENV="$(balena_lib_environment)" \
		-e BALENAOS_TOKEN=$(balena_lib_token) \
		-e NAMESPACE="${NAMESPACE:-resin}" \
		-e MACHINE="${MACHINE}" \
		-e PACKAGES="${PACKAGES}" \
		-e RELEASE_VERSION=$(balena_lib_get_os_version) \
		-e TAG=${balena_yocto_scripts_revision} \
		-e WORKSPACE=/yocto/resin-board \
		-v "${WORKSPACE:-"${PWD}"}":/yocto/resin-board \
		--privileged \
		${NAMESPACE}/yocto-block-build-env:${balena_yocto_scripts_revision} /balena-deploy-block.sh
}

# Initialize a compose file in the specified path
#
# Input:
# $1: Path to create the compose file into
__init_compose() {
	local _path="${1}"
	[ -z "${_path}" ] && return
	cat << EOF > "${_path}/docker-compose.yml"
version: '2'
services:
EOF
}

# Add a compose service
#
# Inputs:
# $1: Path to the directory holding the compose file - will be created if needed
# $2: Name of the service to be added
# $3: Image digest for the service
# $4: Image class: fileset, overlay or service (default)
# $5: Image reboot required: 0 (default) or 1
# $6: Image engine type: boot, root or data (default)
#
# Outputs:
#    Compose file in the specified path
#
__add_compose_service() {
	local _path=$1
	local _service_name=$2
	local _image=$3
	local _image_class=$4
	local _image_reboot=$5
	local _image_engine=$6

	[ -z "${_path}" ] || [ -z "${_service_name}" ] || [ -z "${_image}" ] && return
	_image_class=${_image_class:-"service"}
	_image_reboot=${_image_reboot:-0}
	_image_engine=${_image_engine:-"data"}

	if [ ! -f "${_path}/docker-compose.yml" ]; then
		__init_compose "${_path}"
	fi
	printf "  %s:\n" "${_service_name}" >> "${_path}/docker-compose.yml"
	printf "    image: %s\n" "${_image}" >> "${_path}/docker-compose.yml"
	printf "    labels:\n" >> "${_path}/docker-compose.yml"
	if [ -n "${_image_class}" ]; then
		printf "      io.balena.image.class: %s\n" \""${_image_class}"\" >> "${_path}/docker-compose.yml"
	fi
	if [ "${_image_reboot}" = "1" ]; then
		printf "      io.balena.image.requires-reboot: '1'\n" >> "${_path}/docker-compose.yml"
	fi
	if [ -n "${_image_engine}" ]; then
		printf "      io.balena.image.store: %s\n" \""${_image_engine}"\" >> "${_path}/docker-compose.yml"
	fi
}

# Creates a compose file
#
# Inputs:
# $1: Device type to build for
# $2: Balena API environment (default to balena-cloud.com)
# $3: BalenaOS version - defaults to current device repository tag
# $4: HostOS blocks - default to none
#
# Outputs:
#    Path where the compose file is created
#
__create_compose_file() {
	local _machine="$1"
	local _apiEnv="$2"
	local _version="$3"
	local _hostOSBlocks="$4"
	local _path
	local _bootable_image
	local _block_image

	[ -z "${_machine}" ] && return
	_version=${version:-$(balena_lib_get_os_version)}
	_apiEnv=${_apiEnv:-"balena-cloud.com"}
	[ -z "${_path}" ] && _path=$(mktemp -d)

	_bootable_image=$(fetch_image_from_app "${_machine}" "${_version}" "${_apiEnv}")
	__add_compose_service "${_path}" "bootable" "${_bootable_image}" "service" "1" "root"
	for block in ${_hostOSBlocks}; do
		_block_image=$(fetch_image_from_app "${_machine}-${block}" "${_version}" "${_apiEnv}")
		__add_compose_service "${_path}" "${block}" "${_block_image}" "overlay" "1" "data"
	done
	echo "${_path}"
}

# Deploys a multi-container hostOS
#
# Inputs:
# $1: Application name
# $2: Device type for the application
# $3: Balena API environment (default to balena-cloud.com)
# $4: HostOS blocks - default to none
# $5: Balena API token (defaults to ~/.balena/token)
# $6: Balena cloud account (defaults to balena_os)
#
# Outputs:
#    Path where the compose file is created
#
balena_deploy_hostos() {
	local _appName="$1"
	local _machine="$2"
	local _apiEnv="$3"
	local _hostOSBlocks="$4"
	local _token="$5"
	local _account="$6"
	local _apiEnv
	local _path

	_apiEnv=${_apiEnv:-"balena-cloud.com"}
	_account=${_account:-"balena_os"}
	if [ -z "${_token}" ]; then
		if [ -f "${HOME}/.balena/token" ]; then
			_token=$(cat "${HOME}/.balena/token")
		else
			echo "Balena token is required"
			return
		fi
	fi
	_version=$(balena_lib_get_os_version)
	[ -z "${_version}" ] && >&2 echo "Invalid version" && return
	_path=$(__create_compose_file "${_machine}" "${_apiEnv}" "${_version}" "${hostOSBlocks}")
	if [ -n "${balenaCloudEmail}" ] && [ -n "${balenaCloudPassword}" ]; then
		balena_api_create_public_app "${_appName}" "${_apiEnv}" "${_machine}" "${balenaCloudEmail}" "${balenaCloudPassword}"
	else
		>&2 echo "Balena credentials need to be available in the environment to create public apps"
	fi
	balena_lib_login "${_apiEnv}" "${_token}"
	if [ ! -f "${_path}/docker-compose.yml" ]; then
		>&2 echo "No compose file in ${_path}"
		return
	fi
	_releaseID=$(BALENARC_BALENA_URL="${_apiEnv}" balena deploy ${_appName} --build --source "${_path}" | sed -n 's/.*Release: //p')
	echo "${_releaseID} deployed to ${_appName}"
	balena_api_set_release_version "${_releaseID}" "${_apiEnv}" "${_token}" "$(balena_lib_get_os_version)"
}
