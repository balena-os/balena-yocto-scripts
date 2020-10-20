#!/bin/bash

CURL="curl -s"

TRANSLATION=${TRANSLATION:-"v6"}

DEBUG=0
pp_json() {
	if [ "${DEBUG}" = "1" ]; then
		echo "${1}" | >&2 jq .
	fi
}

# Returns success if the check fails
check_fail() {
	local _json
	local _msg
	_json="$1"
	_msg="$2"

	if [ "${_json}" != "OK" ]; then
		pp_json "${_json}"
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
print_appID_from_appName() {
	local _appName="$1"
	local _apiEnv="$2"
	[ -z "${_appName}" ] && >&2 echo "Application name is required" && return 1
	local _appID=""
	local _json=""
	local _admin=${BALENA_ADMIN:-balena_os}
	_json=$(${CURL} -XGET "https://api.${_apiEnv}/${TRANSLATION}/application?\$filter=(slug%20eq%20'${_admin}/${_appName}')" -H "Content-Type: application/json")
	pp_json "${_json}"
	_appID=$(echo "${_json}" | jq --raw-output '.d[0].id')
	>&2 echo "[${_appName}] Application ID is ${_appID}"
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
create_app() {
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
	pp_json "${_json}"
	_appID=$(echo "${_json}" | jq --raw-output '.id')
	[ -z "${_appID}" ] && return
	>&2 echo "[${_appName}] Application ID is ${_appID}"
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
set_public_app() {
	local _appName="$1"
	local _apiEnv="$2"
	local _token="$3"
	[ -z "${_appName}" ] && >&2 echo "Application name is required" && return 1
	local _appID=""
	local _json=""
	local _post_data
	_appID=$(print_appID_from_appName "${_appName}" "${_apiEnv}")
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
	check_fail "${_json}" "[${_appName}]: Failed to set public" && return 1
	_json=$(${CURL} -XGET "https://api.${_apiEnv}/${TRANSLATION}/application(${_appID})?\$filter=is_public%20eq%20true" -H "Content-Type: application/json" -H "Authorization: Bearer ${_token}")
	pp_json "${_json}"
	>&2 echo "[${_appName}] Application ID is ${_appID}"
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
delete_app() {
	local _appName="$1"
	local _apiEnv="$2"
	local _token="$3"
	[ -z "${_appName}" ] && >&2 echo "Application name is required" && return 1
	local _appID=""
	local _json=""
	_appID=$(print_appID_from_appName "${_appName}" "${_apiEnv}")
	if [ "${_appID}" = "null" ]; then
		>&2 echo "[${_appName}] No such application"
		return 1
	fi
	_json=$(${CURL} -XDELETE "https://api.${_apiEnv}/${TRANSLATION}/application(${_appID})" -H "Content-Type: application/json" -H "Authorization: Bearer ${_token}")
	check_fail "${_json}" "[${_appName}] Error deleting application with ID ${_appID}" && return
	>&2 echo "[${_appName}] Application ${_appID} has been deleted"
	echo "${_appID}"
}
