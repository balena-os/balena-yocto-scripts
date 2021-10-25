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

echo "[INFO] Deploying  to ${BALENAOS_ACCOUNT}/$APPNAME"
balena_api_create_public_app "${APPNAME}" "${BALENARC_BALENA_URL}" "${MACHINE}" "${balenaCloudEmail}" "${balenaCloudPassword}" "${BOOTABLE}"
_releaseID=$(balena_lib_release "${BALENAOS_ACCOUNT}/$APPNAME" "${FINAL}" "/deploy" "${API_ENV}" "$_local_image")
if [ -z "${_releaseID}" ]; then
	echo "[INFO] Failed to deploy to ${BALENAOS_ACCOUNT}/$APPNAME"
	exit 1
fi

# Legacy hostapp tagging
if [ "${FINAL}" = "1" ] && [ -n "${VARIANT}" ]; then
	if [ "${VARIANT}" = "dev" ]; then
		variant_str="development"
	else
		variant_str="production"
	fi
	_version=$(balena_api_get_final_release "${BALENAOS_ACCOUNT}/${APPNAME}" "${META_BALENA_VERSION}" "${API_ENV}" "${BALENAOS_TOKEN}")
	_os_version=$(balena_lib_get_os_version)
	if [ "${_version}" != "${_os_version}" ]; then
		echo "balena-deploy-block: Version mismatch, OS version is ${_os_version} and deployed version is ${_version}"
		exit 1
	fi
	echo "[INFO] Tagging release ${_releaseID} with version ${_version} and variant ${variant_str}"
	balena tag set version "${_version}" --release "${_releaseID}"
	balena tag set variant "${variant_str}" --release "${_releaseID}"
	if [ "$ESR" = "true" ]; then
		balena tag set meta-balena-base "${META_BALENA_VERSION}" --release "${_releaseID}"
	fi
fi

balena_docker_stop
exit 0
