#!/bin/bash
set -e

script_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
device_dir=$(realpath "${script_dir}/../../")
BALENA_YOCTO_SCRIPTS_REVISION=$(cd "${script_dir}" && git rev-parse --short HEAD)

# Return the latest tag of the device repository
balena_lib_get_os_version() {
	pushd "${device_dir}" > /dev/null 2>&1 || return
	_version=$(git describe --abbrev=0)
	popd > /dev/null 2>&1 || return
	echo "${_version#v*}"
}

# Return the latest tag of the meta-balena repository
balena_lib_get_meta_balena_version() {
	pushd "${device_dir}/layers/meta-balena" > /dev/null 2>&1 || return
	_version=$(git describe --abbrev=0)
	popd > /dev/null 2>&1 || return
	echo "${_version#v*}"
}

# Pull a helper image building a matching version if required
# Inputs:
# $1: Dockerfile name
balena_lib_docker_pull_helper_image() {
	local _dockerfile_name="$1"
	local _image_name=""
	local _image_prefix=""
	local _retvalue="$2"
	_image_name="${_dockerfile_name%".template"}"
	_image_name="${_image_name#"Dockerfile_"}"
	case ${_dockerfile_name} in
		*template)
			_image_prefix="${MACHINE}-"
			DEVICE_ARCH=$(jq --raw-output '.arch' "$WORKSPACE/$MACHINE.json")
			export DEVICE_ARCH
			DEVICE_TYPE=${MACHINE}
			export DEVICE_TYPE
			;;
	esac

	if ! docker pull "${NAMESPACE}"/"${_image_prefix}""${_image_name}":"${BALENA_YOCTO_SCRIPTS_REVISION}"; then
		JOB_NAME="${JOB_NAME}" DOCKERFILES="${_dockerfile_name}" "${script_dir}/jenkins_build-containers.sh"
	fi
	eval "$_retvalue"='${BALENA_YOCTO_SCRIPTS_REVISION}'
}

# Remove all versions of a  helper image
# Inputs:
# $1: Image name
#
balena_lib_docker_remove_helper_images() {
    local _image_name="${1}"
    local _image_ids
    local _id
    _image_ids=$(docker images "${NAMESPACE}/${_image_name}" --format "{{.ID}}")
    for _id in ${_image_ids}; do
        docker rmi -f "${_id}" || true
    done
}

# Outputs to Balena environment according to Jenkins "deployTo" environment variables
balena_lib_environment() {
	local _api_env
	if [ -n "${deployTo}" ]; then
		if [ "${deployTo}" = "staging" ]; then
			_api_env="balena-staging.com"
		elif [ "${deployTo}" = "production" ]; then
			_api_env="balena-cloud.com"
		fi
	else
		echo "Defaulting to balena-cloud.com"
		_api_env="balena-cloud.com"
	fi
	export BALENARC_BALENA_URL=${_api_env}
	echo "${_api_env}"
}

# Output the Balena environment token according to set environment
balena_lib_token() {
	local _api_env
	[ -z "${_api_env}" ] && _api_env=$(balena_lib_environment)
	if [ "${_api_env}" = "balena-staging.com" ]; then
		if [ -n "${BALENAOS_STAGING_TOKEN}" ]; then
			_token="${BALENAOS_STAGING_TOKEN}"
		fi
	elif [ "${_api_env}" = "balena-cloud.com" ]; then
		if [ -n "${BALENAOS_PRODUCTION_TOKEN}" ]; then
			_token="${BALENAOS_PRODUCTION_TOKEN}"
		fi
	fi
        if [ -z "${_token}" ]; then
            if [ -f "${HOME}/.balena/token" ]; then
                _token="$(cat "${HOME}/.balena/token")"
            else
                return
            fi
        fi
	echo "${_token}"
}

# Logins to Balena cloud
balena_lib_login() {
	local _api_env=$1
	local _token=$2

	[ -z "${_api_env}" ] && _api_env=$(balena_enviroment)
	if [ -z "${_api_env}" ]; then
		echo "A Balena environment is required"
		return
	fi
	[ -z "${_token}" ] && _token=$(balena_lib_token)
	if [ -z "${_token}" ]; then
		echo "A Balena token is required"
		return
	fi
	BALENARC_BALENA_URL=${_api_env} balena login --token "${_token}"
}

# Login to dockerhub
balena_lib_dockerhub_login() {
    local _user="${1}"
    local _pwd="${2}"

    if [ -z "${_user}" ]; then
        if [ -n "${JOB_NAME}" ]; then
            _user="${DOCKERHUB_USER:-"balenadevices"}"
            echo "Login to docker as ${_user}"
        fi
    fi

    if [ -z "${_pwd}" ]; then
        if [ -n "${JOB_NAME}" ]; then
            _pwd=${DOCKERHUB_PWD:-"${balenadevicesDockerhubPassword}"}
        fi
    fi

    # Fallback to interactive or cached credentials
    docker login -u "${_user}" -p "${_pwd}"
}