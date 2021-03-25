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
