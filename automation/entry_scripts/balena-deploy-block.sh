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
balena_api_create_public_app "${APPNAME}" "${BALENARC_BALENA_URL}" "${MACHINE}" "${balenaCloudEmail}" "${balenaCloudPassword}" "${ESR}" "${BOOTABLE}"
_releaseID=$(balena_lib_release "${BALENAOS_ACCOUNT}/$APPNAME" "${FINAL}" "/deploy" "${API_ENV}" "$_local_image")
if [ -z "${_releaseID}" ]; then
	echo "[INFO] Failed to deploy to ${BALENAOS_ACCOUNT}/$APPNAME"
	exit 1
fi

# Legacy hostapp tagging
if [ "${DEPLOY}" = "yes" ]; then
	_version=$(balena_api_get_version "${_releaseID}" "${API_ENV}" "${BALENAOS_TOKEN}")
	_os_version=$(balena_lib_get_os_version)
	# 0.0.0 is a reserved version used when the semver is not set
	if [ "${_version%-*}" != "0.0.0" ] && [ "${_version}" != "${_os_version}" ]; then
		echo "balena-deploy-block: Version mismatch, OS version is ${_os_version} and deployed version is ${_version}"
		exit 1
	fi
	if balena_api_release_tag_exists "${BALENAOS_ACCOUNT}/$APPNAME" "version" "${_os_version}" "${API_ENV}" "${BALENAOS_TOKEN}" > /dev/null; then
			echo "[WARN] Release ID ${_releaseID} is already tagged with version ${_os_version} - bailing out"
			exit 0
	fi
	echo "[INFO] Tagging release ${_releaseID} with version ${_os_version}"
	balena tag set version "${_os_version}" --release "${_releaseID}"
	balena release finalize "${_releaseID}"
	if [ "$ESR" = "true" ]; then
		_regex="^[1-3][0-9]{3}\.${Q1ESR}|${Q2ESR}|${Q3ESR}|${Q4ESR}\.[0-9]*$"

		if ! echo "${RELEASE_VERSION}" | grep -Eq "${_regex}"; then
			>&2 echo "Invalid ESR release ${RELEASE_VERSION}"
			exit 1
		fi
		balena tag set meta-balena-base "${META_BALENA_VERSION}" --release "${_releaseID}"

		last_current=$(balena_api_fetch_fleet_tag "$APPNAME" "esr-current" "${API_ENV}" || true)
		last_sunset=$(balena_api_fetch_fleet_tag "$APPNAME" "esr-sunset" "${API_ENV}" || true)
		last_next=$(balena_api_fetch_fleet_tag "$APPNAME" "esr-next" "${API_ENV}" || true)
		if [ "${last_current}" = "null" ]; then
			echo "[INFO][${BALENAOS_ACCOUNT}/${APPNAME}] Tagging fleet with esr-current: ${RELEASE_VERSION}"
			balena tag set esr-current "${RELEASE_VERSION}" --fleet "${BALENAOS_ACCOUNT}/$APPNAME"
		elif [ "${last_sunset}" = "null" ]; then
			if [ "${last_next}" = "null" ]; then
				echo "[INFO][${BALENAOS_ACCOUNT}/${APPNAME}] Tagging fleet with esr-next: ${RELEASE_VERSION}"
				balena tag set esr-next "${RELEASE_VERSION}" --fleet "${BALENAOS_ACCOUNT}/$APPNAME"
			else
				echo "[INFO][${BALENAOS_ACCOUNT}/${APPNAME}] Tagging fleet with esr-next: ${RELEASE_VERSION} esr-current: ${last_next} esr-sunset: ${last_current}"
				balena tag set esr-next "${RELEASE_VERSION}" --fleet "${BALENAOS_ACCOUNT}/$APPNAME"
				balena tag set esr-current "${last_next}" --fleet "${BALENAOS_ACCOUNT}/$APPNAME"
				balena tag set esr-sunset "${last_current}" --fleet "${BALENAOS_ACCOUNT}/$APPNAME"
			fi
		else
			if [ "${last_next}" = "null" ]; then
				>&2 echo "Invalid fleet tags: current: ${last_current} next: ${last_next} sunset: ${last_sunset}"
				exit 1
			else
				echo "[INFO][${BALENAOS_ACCOUNT}/${APPNAME}] Tagging fleet with esr-next: ${RELEASE_VERSION} esr-current: ${last_next} esr-sunset: ${last_current}"
				balena tag set esr-next "${RELEASE_VERSION}" --fleet "${BALENAOS_ACCOUNT}/$APPNAME"
				balena tag set esr-current "${last_next}" --fleet "${BALENAOS_ACCOUNT}/$APPNAME"
				balena tag set esr-sunset "${last_current}" --fleet "${BALENAOS_ACCOUNT}/$APPNAME"
			fi
		fi
	fi
fi

balena_docker_stop
exit 0
