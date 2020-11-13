#!/bin/bash

script_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
BALENA_YOCTO_SCRIPTS_REVISION=$(cd "${script_dir}" && git rev-parse --short HEAD)

# Pull a helper image building a matching version if required
# Inputs:
# $1: Dockerfile name
docker_pull_helper_image() {
	local _dockerfile_name="$1"
	local _image_name=""
	local _image_prefix=""
	_image_name="${_dockerfile_name%".template"}"
	_image_name="${_image_name#"Dockerfile_"}"
	case ${_dockerfile_name} in
		*template)
			_image_prefix="${MACHINE}-"
			export DEVICE_ARCH=$(jq --raw-output '.arch' "$WORKSPACE/$MACHINE.json")
			export DEVICE_TYPE=${MACHINE}
			;;
	esac

	if ! docker pull "${NAMESPACE}"/"${_image_prefix}""${_image_name}":"${BALENA_YOCTO_SCRIPTS_REVISION}"; then
		if [ "${deploy}" = "yes" ]; then
			DOCKERHUB_USER="${DOCKERHUB_USER:-"balenadevices"}"
			DOCKERHUB_PWD=${DOCKERHUB_PWD:-"balenadevicesDockerhubPassword"}
			echo "Login to docker as ${DOCKERHUB_USER}"
			docker login -u "${DOCKERHUB_USER}" -p "${DOCKERHUB_PWD}"
			JOB_NAME="${JOB_NAME}" DOCKERFILES="${_dockerfile_name}" ${script_dir}/jenkins_build-containers.sh
		else
			echo "No ${_image_name} container deployed"
			echo "Run with the deploy argument to build and deploy the builder containers"
			return 1
		fi
	fi
}
