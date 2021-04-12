#!/bin/bash

CURL="curl -s"

TRANSLATION=${TRANSLATION:-"v6"}

DEBUG=0
__pp_json() {
	if [ "${DEBUG}" = "1" ]; then
		echo "${1}" | >&2 jq .
	fi
}

__dlog() {
	if [ "${DEBUG}" = "1" ]; then
		>&2 echo "${1}"
	fi
}

# Returns success if the check fails
__check_fail() {
	local _json
	local _msg
	_json="$1"
	_msg="$2"

	if [ "${_json}" != "OK" ]; then
		__pp_json "${_json}"
		>&2 echo "${_msg}"
		return 0
	fi
	return 1
}

# Print application ID from application name
# Arguments:
#
# $1: Application name
# $2: Balena target environment
#
# Result:
# Prints the application ID or null if it does not exist
balena_api_appID_from_appName() {
	local _appName="$1"
	local _apiEnv="$2"
	local _token="${3:-""}"
	[ -z "${_appName}" ] && >&2 echo "Application name is required" && return 1
	local _appID=""
	local _json=""
	local _admin=${BALENA_ADMIN:-balena_os}
	# Unauthenticated only shows public apps
	if [ -z "${_token}" ]; then
		if [ -f "${HOME}/.balena/token" ]; then
			_token=$(cat "${HOME}/.balena/token")
		fi
	fi
	if [ "${_token}" ]; then
		_json=$(${CURL} -XGET "https://api.${_apiEnv}/${TRANSLATION}/application?\$filter=(slug%20eq%20'${_admin}/${_appName}')" -H "Content-Type: application/json" -H "Authorization: Bearer ${_token}")
	else
		__dlog echo "Accessing only public apps"
		_json=$(${CURL} -XGET "https://api.${_apiEnv}/${TRANSLATION}/application?\$filter=(slug%20eq%20'${_admin}/${_appName}')" -H "Content-Type: application/json")
	fi
	__pp_json "${_json}"
	_appID=$(echo "${_json}" | jq --raw-output '.d[0].id')
	__dlog "[${_appName}] Application ID is ${_appID}"
	echo "${_appID}"
}

# Creates an  application
# Arguments:
#
# $1: Application name
# $2: Balena target environment
# $3: Balena environment token
# $4: Device type
#
# Result:
# 	Application ID of the app created or null
__create_app() {
	local _appName="$1"
	local _apiEnv="$2"
	local _token="$3"
	local _device_type="$4"
	[ -z "${_appName}" ] && >&2 echo "Application name is required" && return 1
	[ -z "${_device_type}" ] && >&2 echo "Device type is required" && return 1
	local _appID=""
	local _json=""
	local _post_data
	while read -r -d '' _post_data <<-EOF
{
	"app_name": "${_appName}",
	"device_type": "${_device_type}"
}
EOF
do
	# This avoid read returning error from not finding a newline termination
	:
done
	_json=$(${CURL} -XPOST "https://api.${_apiEnv}/${TRANSLATION}/application" -H "Content-Type: application/json" -H "Authorization: Bearer ${_token}" --data "${_post_data}")
	__pp_json "${_json}"
	_appID=$(echo "${_json}" | jq --raw-output '.id' || true)
	[ -z "${_appID}" ] && return
	__dlog "[${_appName}] Application ID is ${_appID}"
	echo "${_appID}"
}

# Sets an  application public
# Arguments:
#
# $1: Application name
# $2: Balena target environment
# $3: Balena environment token
#
# Result:
# 	Application ID of the public app or null
__set_public_app() {
	local _appName="$1"
	local _apiEnv="$2"
	local _token="$3"
	[ -z "${_appName}" ] && >&2 echo "Application name is required" && return 1
	local _appID=""
	local _json=""
	local _post_data
	_appID=$(balena_api_appID_from_appName "${_appName}" "${_apiEnv}" "${_token}")
	if [ "${_appID}" = "null" ]; then
		>&2 echo "[${_appName}] No such application"
		return 1
	fi
	while read -r -d '' _post_data <<-'EOF'
{
	"is_public": true
}
EOF
do
	# This avoid read returning error from not finding a newline termination
	:
done
_json=$(${CURL} -XPATCH "https://api.${_apiEnv}/${TRANSLATION}/application(${_appID})" -H "Content-Type: application/json" -H "Authorization: Bearer ${_token}" --data "${_post_data}")
	__check_fail "${_json}" "[${_appName}]: Failed to set public" && return 1
	_json=$(${CURL} -XGET "https://api.${_apiEnv}/${TRANSLATION}/application(${_appID})?\$filter=is_public%20eq%20true" -H "Content-Type: application/json" -H "Authorization: Bearer ${_token}")
	__pp_json "${_json}"
	__dlog "[${_appName}] Application ID is ${_appID}"
	echo "${_appID}"
}

# Sets an application bootable
# Arguments:
#
# $1: Application name
# $2: Balena target environment
# $3: Balena environment token
#
# Result:
# 	Application ID of the bootable app or null
__set_bootable_app() {
	local _appName="$1"
	local _apiEnv="$2"
	local _token="$3"
	[ -z "${_appName}" ] && >&2 echo "Application name is required" && return 1
	local _appID=""
	local _json=""
	local _post_data
	_appID=$(balena_api_appID_from_appName "${_appName}" "${_apiEnv}" "${_token}")
	if [ "${_appID}" = "null" ]; then
		>&2 echo "[${_appName}] No such application"
		return 1
	fi
	while read -r -d '' _post_data <<-'EOF'
{
	"is_host": true
}
EOF
do
	# This avoid read returning error from not finding a newline termination
	:
done
_json=$(${CURL} -XPATCH "https://api.${_apiEnv}/${TRANSLATION}/application(${_appID})" -H "Content-Type: application/json" -H "Authorization: Bearer ${_token}" --data "${_post_data}")
	__check_fail "${_json}" "[${_appName}]: Failed to set bootable" && return 1
	_json=$(${CURL} -XGET "https://api.${_apiEnv}/${TRANSLATION}/application(${_appID})?\$filter=is_host%20eq%20true" -H "Content-Type: application/json" -H "Authorization: Bearer ${_token}")
	__pp_json "${_json}"
	__dlog "[${_appName}] Bootable application ID is ${_appID}"
	echo "${_appID}"
}

# Deletes an application
# Arguments:
#
# $1: Application name
# $2: Balena target environment
# $3: Balena environment token
#
# Result:
# 	Application ID of the app deleted or null
__unused_delete_app() {
	local _appName="$1"
	local _apiEnv="$2"
	local _token="$3"
	[ -z "${_appName}" ] && >&2 echo "Application name is required" && return 1
	local _appID=""
	local _json=""
	_appID=$(balena_api_appID_from_appName "${_appName}" "${_apiEnv}" "${_token}")
	if [ "${_appID}" = "null" ]; then
		>&2 echo "[${_appName}] No such application"
		return 1
	fi
	_json=$(${CURL} -XDELETE "https://api.${_apiEnv}/${TRANSLATION}/application(${_appID})" -H "Content-Type: application/json" -H "Authorization: Bearer ${_token}")
	__check_fail "${_json}" "[${_appName}] Error deleting application with ID ${_appID}" && return
	>&2 echo "[${_appName}] Application ${_appID} has been deleted"
	echo "${_appID}"
}

# Creates a public application
# Arguments:
#
# $1: Application name
# $2: Balena target environment
# $3: Device type
# $4: Balena Cloud Email
# $5: Balena Cloud Password
#
# Result:
# 	Application ID of the app created or null
balena_api_create_public_app() {
	local _appName=$1
	local _apiEnv=$2
	local _device_type=$3
	local _balenaCloudEmail=$4
	local _balenaCloudPassword=$5
	local _bootable=$6
	local _token
	local _appID

        _device_type=$(balena_lib_resolve_aliases "${_device_type}")

	# Admin named API keys have normal user privileges, need to use credentials based  session token instead
	BALENARC_BALENA_URL=${_apiEnv} balena login --credentials --email "${_balenaCloudEmail}" --password "${_balenaCloudPassword}"
	_token=$(cat "${HOME}/.balena/token")
	_appID=$(balena_api_appID_from_appName "${_appName}" "${_apiEnv}" "${_token}")
	if [ -z "${_appID}" ] || [ "${_appID}" = "null" ]; then
		__create_app "${_appName}" "${_apiEnv}" "${_token}" "${_device_type}"
		_appID=$(__set_public_app "${_appName}" "${_apiEnv}" "${_token}" || true)
		if [ -n "${_appID}" ] && [ "${_appID}" != "null" ]; then
			>&2 echo "[${_appName}] Application ${_appID} has been created as public"
		fi
		if [ "${_bootable}" = "1" ]; then
			__set_bootable_app "${_appName}" "${_apiEnv}" "${_token}"
		fi
	else
	    >&2 echo "[${_appName}] Application ${_appID} already exists."
	fi
	echo "${_appID}"
}

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
	_result=$(${CURL} -XPATCH -H "Content-type: application/json" -H "Authorization: Bearer ${_token}" "https://api.${_apiEnv}/${TRANSLATION}/release?\$filter=commit%20eq%20'${_releaseID}'" -d "{\"release_version\": \"${_release_version}\"}")
	if [ "${_result}" = "OK" ]; then
		echo "[INFO] Setting release version of ${_releaseID} to ${_release_version}"
		return 0
	else
		echo "[ERROR] Failed to set release version of ${_releaseID} - is ${_release_version} unique?"
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
