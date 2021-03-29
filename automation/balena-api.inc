#!/bin/bash

CURL="curl -s"

TRANSLATION=${TRANSLATION:-"v6"}

# Sets a release version
# Arguments:
#
# $1: Release ID
# $2: Balena target environment
# $3: Balena API token
# $4: Release version string
#
# Result:
# 	Success or failed.
balena_api_set_release_version () {
	local _releaseID=$1
	local _apiEnv=$2
	local _token=$3
	local _release_version=$4
	local _result
	echo "[INFO] Setting release version of ${_releaseID} to ${_release_version}"
	_result=$(${CURL} -XPATCH -H "Content-type: application/json" -H "Authorization: Bearer ${_token}" "https://api.${_apiEnv}/${TRANSLATION}/release?\$filter=commit%20eq%20'${_releaseID}'" -d "{\"release_version\": \"${_release_version}\"}")
	if [ "${_result}" = "OK" ]; then
		return 0
	else
		return 1
	fi
}

balena_api_is_dt_private() {
	local _device_type="${1}"
	local _slug
	local _api_env
	local _token
	local _is_private
	_slug=$(balena_lib_get_slug "${_device_type}")
	_api_env=$(balena_lib_environment)
	_token=$(balena_lib_token)

	_is_private=$(${CURL} -XGET -H "Content-type: application/json" -H "Authorization: bearer ${_token}" --silent --retry 5 "https://api.${_api_env}/${TRANSLATION}/device_type?\$filter=slug%20eq%20%27${_slug}%27&\$select=slug,is_private" | jq -r '.d[0].is_private')
	if [ -z "${_is_private}" ] || [ "${_is_private}" = "null" ]; then
		>&2 echo "[] Device type not found, assuming private"
		echo "true"
	fi
	echo "${_is_private}"
}
