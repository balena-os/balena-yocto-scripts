#!/bin/bash

set -e

[ -z "${HOSTEXT_NAME}" ] && echo "Hostapp extension  name needs to be defined" && exit 1
[ -z "${MACHINE}" ] && echo "Device type needs to be defined" && exit 1
[ -z "${deployTo}" ] && echo "Deployment environment needs to be defined" && exit 1

source /balena-api.sh

if [ "${deployTo}" = "production" ]; then
	BALENA_TOKEN="${BALENAOS_PRODUCTION_TOKEN}"
	API_ENV=balena-cloud.com
	balenaCloudAccount="balenaCloud-balenaos-staging"
elif [ "${deployTo}" = "staging" ]; then
	BALENA_TOKEN="${BALENAOS_STAGING_TOKEN}"
	API_ENV=balena-staging.com
	balenaCloudAccount="balenaCloud-balenaos-production"
fi

[ -z "${API_ENV}" ] && echo "Target environment is required" && exit 1
[ -z "${BALENA_TOKEN}" ] && echo "API or session token is required" && exit 1


_appID=$(print_appID_from_appName "${HOSTEXT_NAME}" "${API_ENV}")
if [ -z "${_appID}" ] || [ "${_appID}" = "null" ]; then
	create_app "${HOSTEXT_NAME}" "${API_ENV}" "${BALENAOS_TOKEN}" "${MACHINE}"
	# Admin named API keys have normal user privileges, need to use credentials based  session token instead
	BALENARC_BALENA_URL=${API_ENV} balena login --credentials --email "${balenaCloudEmail}" --password "${balenaCloudPassword}"
	set_public_app "${HOSTEXT_NAME}" "${API_ENV}" "$(cat "${HOME}/.balena/token")" || true
fi
exit $?
