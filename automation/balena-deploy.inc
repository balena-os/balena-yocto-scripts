#!/bin/bash
set -e

script_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
device_dir=$(realpath "${script_dir}/../../")
BALENA_YOCTO_SCRIPTS_REVISION=$(cd "${script_dir}" && git rev-parse --short HEAD)

# Deploys to passed container image to BalenaCloud
# Input arguments:
#  $1: Path to the local image to deploy
#  $2: Balena environment
#  $3: Balena API token
#  $4: BalenaOS account (defaults to balena_os)
#  $5: ESR release flag (default to "ESR" environment variable)
#  $6: Development flag (defaults to DEVELOPMENT_IMAGE environment variable)
#  $7: App name to deploy to (defaults to SLUG environment variable)
#
balena_deploy_hostapp() {
	local _image_path="${1}"
	local _api_env="${2}"
	local _token="${3}"
	local _balenaos_account="${4}"
	local _esr="${5}"
	local _variant="${6}"
	local _app="${7}"
	local _version
	if ! balena_lib_docker_pull_helper_image "Dockerfile_balena-push-env" balena_yocto_scripts_revision; then
		exit 1
	fi

	[ -z "${_image_path}" ] && echo "An image is required" && return
	[ -z "${_token}" ] && echo "A Balena token is required" && return
	[ -z "${_api_env}" ] && echo "A Balena environment is required" && return

	_version=${VERSION_HOSTOS:-$(balena_lib_get_os_version)}
	_app=${_app:="${MACHINE}"}
	_esr=${_esr:-"${ESR}"}
	_variant=${_variant:-"${buildFlavor}"}
	_meta_balena_version=${META_BALENA_VERSION:-$(balena_lib_get_meta_balena_version)}
	NAMESPACE=${NAMESPACE:-resin}
        _balenaos_account="${_balenaos_account:-"balena_os"}"

	# shellcheck disable=SC2154
	docker run --rm -t \
		-e BASE_DIR=/host \
		-e TOKEN="${_token}" \
		-e API_ENV="${_api_env}" \
		-e APPNAME="${_app}" \
		-e BALENAOS_ACCOUNT="${_balenaos_account}" \
		-e VARIANT="${_variant}" \
		-e VERSION_HOSTOS="${_version}" \
		-e ESR="${_esr}" \
		-e META_BALENA_VERSION="${_meta_balena_version}" \
		-v "${_image_path}":/host/appimage.docker \
		--privileged \
		"${NAMESPACE}"/balena-push-env:"${balena_yocto_scripts_revision}" /balena-deploy-block.sh

        balena_lib_docker_remove_helper_images "balena-push-env"
}
