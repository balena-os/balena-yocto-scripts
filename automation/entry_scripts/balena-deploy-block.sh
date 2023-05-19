#!/bin/bash
set -e

source /balena-docker.inc
source /balena-lib.inc
source /balena-api.inc

trap 'balena_docker_stop fail' SIGINT SIGTERM

# Start docker
balena_docker_start "/scratch/docker" "/var/run" "/var/log/docker.log"
balena_docker_wait

BALENAOS_ACCOUNT="${BALENAOS_ACCOUNT:-"balena_os"}"
if [ -f "/host/appimage.docker" ]; then
	_local_image=$(docker load -i /host/appimage.docker | cut -d: -f1 --complement | tr -d " " )
fi

echo "[INFO] Logging into $API_ENV as ${BALENAOS_ACCOUNT}"
export BALENARC_BALENA_URL=${API_ENV}
balena login --token "${BALENAOS_TOKEN}"

if [ "$ESR" = "true" ]; then
	echo "Deploying ESR release"
	APPNAME="${APPNAME}-esr"
fi

if [ -f "/deploy/balena.yml" ]; then
	echo -e "\nversion: $(balena_lib_get_os_version)" >> "/deploy/balena.yml"
	if [ "${SECURE_BOOT_FEATURE_FLAG}" = "yes" ]; then
		sed -i '/provides:/a \  - type: sw.feature\n    slug: secureboot' "/deploy/balena.yml"
	fi
fi

echo "[INFO] Deploying  to ${BALENAOS_ACCOUNT}/$APPNAME"
balena_api_create_public_app "${APPNAME}" "${BALENARC_BALENA_URL}" "${MACHINE}" "${balenaCloudEmail}" "${balenaCloudPassword}" "${ESR}" "${BOOTABLE}"
_releaseID=$(balena_lib_release "${BALENAOS_ACCOUNT}/$APPNAME" "${FINAL}" "/deploy" "${API_ENV}" "$_local_image")
if [ -z "${_releaseID}" ]; then
	echo "[INFO] Failed to deploy to ${BALENAOS_ACCOUNT}/$APPNAME"
	exit 1
fi

# Legacy hostapp tagging
if [ "${DEPLOY}" = "yes" ] && [ "${FINAL}" = "yes" ]; then
	balena_lib_release_finalize "${_releaseID}" "${BALENAOS_ACCOUNT}/${APPNAME}" "${API_ENV}" "${BALENAOS_TOKEN}" "${ESR}"
fi

balena_docker_stop
exit 0
