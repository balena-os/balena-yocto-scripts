#!/bin/bash

script_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
BALENA_YOCTO_SCRIPTS_REVISION=$(cd "${script_dir}" && git rev-parse --short HEAD)

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
