#!/bin/bash
set -e

script_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
if [ -f "/balena-lib.inc" ] && [ -f "/balena-api.inc" ] && [ -f "/balena-docker.inc" ]; then
	source "/balena-lib.inc"
	source "/balena-api.inc"
	source "/balena-docker.inc"
else
	automation_dir=$( cd "${script_dir}/.." && pwd )
	source "${automation_dir}/include/balena-lib.inc"
	source "${automation_dir}/include/balena-api.inc"
	source "${automation_dir}/include/balena-docker.inc"
fi

trap 'balena_docker_stop fail' SIGINT SIGTERM

# Start docker
balena_docker_start "/scratch/docker" "/var/run" "/var/log/docker.log"
balena_docker_wait

BALENAOS_ACCOUNT="${BALENAOS_ACCOUNT:-"balena_os"}"

echo "[INFO] Logging into $API_ENV as ${BALENAOS_ACCOUNT}"
export BALENARC_BALENA_URL=${API_ENV}
balena login --token "${BALENAOS_TOKEN}"

if [ "$ESR" = "true" ]; then
	echo "Deploying ESR release"
	APPNAME="${APPNAME}-esr"
fi

# Use /deploy folder to generate compose file to use local images that live there
# Use a release dir to limit context
RELEASE_DIR=$(balena_docker_create_compose_file "${MACHINE}" "${API_ENV}" "${RELEASE_VERSION}" "${BALENAOS_TOKEN}" "${BLOCKS}" "/deploy")
if [ ! -f "${RELEASE_DIR}/docker-compose.yml" ]; then
	echo "[ERROR] Failed to generate compose file"
	exit 1
fi

if [ -f "/deploy/balena.yml" ]; then
	cp "/deploy/balena.yml" "${RELEASE_DIR}"
	echo -e "\nversion: $(balena_lib_get_os_version)" >> "${RELEASE_DIR}/balena.yml"
fi

echo "[INFO] Deploying  to ${BALENAOS_ACCOUNT}/$APPNAME"
balena_api_create_public_app "${APPNAME}" "${BALENARC_BALENA_URL}" "${MACHINE}" "${balenaCloudEmail}" "${balenaCloudPassword}" "${ESR}" "${BOOTABLE}"
_releaseID=$(balena_lib_release "${BALENAOS_ACCOUNT}/$APPNAME" "${FINAL}" "${RELEASE_DIR}" "${API_ENV}")
if [ -z "${_releaseID}" ]; then
	echo "[INFO] Failed to deploy to ${BALENAOS_ACCOUNT}/$APPNAME"
	exit 1
fi

# Legacy hostapp tagging
if [ "${FINAL}" = "yes" ]; then
	balena_lib_release_finalize "${_releaseID}" "${BALENAOS_ACCOUNT}/${APPNAME}" "${API_ENV}" "${BALENAOS_TOKEN}" "${ESR}"
fi

balena_docker_stop
rm -rf "${RELEASE_DIR:?}"
exit 0
