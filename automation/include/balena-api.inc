#!/bin/bash

CURL="curl -s"

script_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
device_dir=$( if cat /proc/self/cgroup | grep -q docker; then if [ -d "/work" ]; then cd "/work" && pwd; fi; else cd "${script_dir}/../../.." && pwd; fi )

TRANSLATION=${TRANSLATION:-"v6"}

BALENA_HOSTOS_BLOCK_CLASS="io.balena.image.class"
BALENA_HOSTOS_BLOCK_STORE="io.balena.image.store"
BALENA_HOSTOS_BLOCK_REQUIRES_REBOOT="io.balena.image.requires-reboot"
BALENA_HOSTOS_BLOCK_BOOTABLE="io.balena.image.bootable"
BALENA_HOSTOS_APP_UUID="io.balena.app-uuid"
BALENA_HOSTOS_APP_ID="io.balena.app-id"
BALENA_HOSTOS_RELEASE_VERSION="io.balena.release-version"
BALENA_HOSTOS_SERVICE_NAME="io.balena.service-name"

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
		__dlog "${_msg}"
		return 0
	fi
	return 1
}

# Print application ID from application name
# Arguments:
#
# $1: Application name
# $2: Balena target environment
# $3: Balena API token
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
# $4: Public URL for the application
#
# Result:
# 	Application ID of the public app or null
__set_public_app() {
	local _appName="$1"
	local _apiEnv="$2"
	local _token="$3"
	local _url="${4}"
	[ -z "${_appName}" ] && >&2 echo "Application name is required" && return 1
	local _appID=""
	local _json=""
	local _post_data
	_appID=$(balena_api_appID_from_appName "${_appName}" "${_apiEnv}" "${_token}")
	if [ "${_appID}" = "null" ]; then
		>&2 echo "[${_appName}] No such application"
		return 1
	fi
	while read -r -d '' _post_data <<-EOF
{
	"is_public": true,
	"is_stored_at__repository_url": "${_url}"
}
EOF
do
	# This avoid read returning error from not finding a newline termination
	:
done
	_json=$(${CURL} -XPATCH "https://api.${_apiEnv}/${TRANSLATION}/application(${_appID})" -H "Content-Type: application/json" -H "Authorization: Bearer ${_token}" --data "${_post_data}")
	__check_fail "${_json}" "[${_appName}]: Failed to set public" && return 1
	_json=$(${CURL} -XGET "https://api.${_apiEnv}/${TRANSLATION}/application(${_appID})?\$filter=(is_public%20eq%20truel20and%20(is_stored_at__repository_url%20eq%20'${_url}')" -H "Content-Type: application/json" -H "Authorization: Bearer ${_token}")
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

# Sets an  application repository URL
# Arguments:
#
# $1: Application name
# $2: Balena target environment
# $3: Balena environment token
# $4: Repository URL
#
# Result:
# 	Application ID of the public app that had the repository URL set or null
balena_api_set_app_url() {
	local _appName="$1"
	local _apiEnv="$2"
	local _token="$3"
	local _url="${4}"
	[ -z "${_appName}" ] && >&2 echo "Application name is required" && return 1
	local _appID=""
	local _json=""
	local _post_data
	_appID=$(balena_api_appID_from_appName "${_appName}" "${_apiEnv}" "${_token}")
	if [ "${_appID}" = "null" ]; then
		>&2 echo "[${_appName}] No such application"
		return 1
	fi
	while read -r -d '' _post_data <<-EOF
{
	"is_stored_at__repository_url": "${_url}"
}
EOF
do
	# This avoid read returning error from not finding a newline termination
	:
done
	_json=$(${CURL} -XPATCH "https://api.${_apiEnv}/${TRANSLATION}/application(${_appID})" -H "Content-Type: application/json" -H "Authorization: Bearer ${_token}" --data "${_post_data}")
	__check_fail "${_json}" "[${_appName}]: Failed to set URL" && return
	_json=$(${CURL} -XGET "https://api.${_apiEnv}/${TRANSLATION}/application(${_appID})?\$filter=is_stored_at__repository_url%20eq%20'${_url}'" -H "Content-Type: application/json" -H "Authorization: Bearer ${_token}")
	__pp_json "${_json}"
	>&2 echo "[${_appName}] Application ID is ${_appID}"
	echo "${_appID}"
}

_get_device_family() {
	local _family
	pushd "${device_dir}" > /dev/null
	_family=$(git remote get-url origin)
	popd > /dev/null
	_family=${_family##*/}
	_family=${_family%".git"}
	echo "${_family}"
}

# Creates a public application
# Arguments:
#
# $1: Application name
# $2: Balena target environment
# $3: Device type
# $4: Balena Cloud Email
# $5: Balena Cloud Password
# $6: Set bootable (isHost) flag  (optional)
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
	local _url="https://github.com/balena-os"
	local _family

	_device_type=$(balena_lib_resolve_aliases "${_device_type}")

	# Admin named API keys have normal user privileges, need to use credentials based  session token instead
	BALENARC_BALENA_URL=${_apiEnv} balena login --credentials --email "${_balenaCloudEmail}" --password "${_balenaCloudPassword}"
	_token=$(cat "${HOME}/.balena/token")
	_family=$(_get_device_family)
	_url="${_url}/${_family}"
	_appID=$(balena_api_appID_from_appName "${_appName}" "${_apiEnv}" "${_token}")
	if [ -z "${_appID}" ] || [ "${_appID}" = "null" ]; then
		__create_app "${_appName}" "${_apiEnv}" "${_token}" "${_device_type}"
		_appID=$(__set_public_app "${_appName}" "${_apiEnv}" "${_token}" "${_url}" || true)
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

# Checks if the given device type is private
# Arguments:
#
# $1: Device type
#
# Result:
# 	True if private, false otherwise.
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

# Gets a release
# Arguments:
#
# $1: Application name
# $2: Release version string (typically a semver of the form M.m.p)
# $3: Balena target environment
# $4: Balena API token
#
# Result:
# 	Success or failed.
balena_api_get_release() {
	local _appName=$1
	local _release_version=$2
	local _apiEnv=$3
	local _token=$4
	local _appID
	local _json
	_appID=$(balena_api_appID_from_appName "${_appName}" "${_apiEnv}" "${_token}")
	if [ "${_appID}" = "null" ]; then
		>&2 echo "[${_appName}] No such application"
		return 1
	fi
	 __dlog "Fetch release ${_release_version} from ${_appName}"
	 _json=$(${CURL} -XGET -H "Content-type: application/json" "https://api.${_apiEnv}/${TRANSLATION}/release?\$filter=(belongs_to__application%20eq%20${_appID})%20and%20(release_version%20eq%20%27${_release_version}%27)")
	 echo "${_json}"
	_result=$(echo "${_json}" | jq -e '.d[0].id')
	return "$?"
}

# Output a space separated list of images labelled for the given store
#
# Inputs:
#
# $1: Application name
# $2: Release version
# $3: Store type
# $4: Balena API environment (defaults to balena-cloud.com)
# $5: Balena API token
#
balena_api_get_images_for_store() {
	local _app_name="${1}"
	local _release_version="${2}"
	local _store="${3}"
	local _api_env="${4:-"balena-cloud.com"}"
	local _token="${5}"
	local _release

	if [ -z "${_app_name}" ] || [ -z "${_release_version}" ] || [ -z "${_store}" ]; then
		return
	fi

	_release=$(balena_api_get_release "${_app_name}" "${_release_version}" "${_api_env}" "${_token}")
	[ "${_release}" = "null " ] && return
	_images=$(echo "${_release}" | jq -r '.d[0].composition.services[] | select(.labels["'${BALENA_HOSTOS_BLOCK_STORE}'"] == "'"${_store}"'") | .image' 2> /dev/null | tr "\n" " ")
	echo "${_images}"
}

# Output a space separated list of images labelled with the given class
#
# Inputs:
#
# $1: Application name
# $2: Release version
# $3: Class type
# $4: Balena API environment (defaults to balena-cloud.com)
# $5: Balena API environment token
#
balena_api_get_images_with_class() {
	local _app_name="${1}"
	local _release_version="${2}"
	local _class="${3}"
	local _api_env="${4:-"balena-cloud.com"}"
	local _token="${5}"
	local _release

	if [ -z "${_app_name}" ] || [ -z "${_release_version}" ] || [ -z "${_class}" ] || [ -z "${_token}" ]; then
		return
	fi

	_release=$(balena_api_get_release "${_app_name}" "${_release_version}" "${_api_env}" "${_token}")
	[ "${_release}" = "null " ] && return
	_images=$(echo "${_release}" | jq -r '.d[0].composition.services[] | select(.labels["'${BALENA_HOSTOS_BLOCK_CLASS}'"] == "'"${_class}"'") | .image' 2> /dev/null | tr "\n" " ")
	echo "${_images}"
}

# Output a space separated list of images for a given store and labelled with the given class
#
# Inputs:
#
# $1: Application name
# $2: Release version
# $3: Class type
# $4: Store type
# $5: Balena API environment (defaults to balena-cloud.com)
# $6: Balena API token
# $7: Bootable flag (optional, not used to filter if not provided)
#
balena_api_get_images_for_store_with_class() {
	local _app_name="${1}"
	local _release_version="${2}"
	local _class="${3}"
	local _store="${4}"
	local _api_env="${5:-"balena-cloud.com"}"
	local _token="${6}"
	local _bootable="${7}"
	local _release
	local _images
	local _json

	if [ -z "${_app_name}" ] || [ -z "${_release_version}" ] || [ -z "${_class}" ] || [ -z "${_store}" ]; then
		return
	fi

	_release=$(balena_api_get_release "${_app_name}" "${_release_version}" "${_api_env}" "${_token}")
	[ "${_release}" = "null " ] && return
	_json=$(echo "${_release}" | jq -r '.d[0].composition.services[] | select(.labels["'${BALENA_HOSTOS_BLOCK_CLASS}'"] == "'"${_class}"'") | select(.labels["'"${BALENA_HOSTOS_BLOCK_STORE}"'"] == "'"${_store}"'")' 2> /dev/null)
	if [ -n "${_bootable}" ]; then
		_json=$(echo "${_json}" | jq -r '. | select(.labels["'"${BALENA_HOSTOS_BLOCK_BOOTABLE}"'"] == "'"${_bootable}"'")' 2> /dev/null)
	fi
	_images=$(echo "${_json}" | jq -r '.image' 2> /dev/null | tr "\n" " ")
	echo "${_images}"
}

# Output a space separated list of labels for a given release version
#
# Inputs:
#
# $1: Application name
# $2: Release version
# $3: Balena API environment (defaults to balena-cloud.com)
# $4: Balena API token
#
balena_api_get_image_labels() {
	local _app_name="${1}"
	local _release_version="${2}"
	local _api_env="${3:-"balena-cloud.com"}"
	local _token="${4}"
	local _labels

	if [ -z "${_app_name}" ] || [ -z "${_release_version}" ]; then
		return
	fi

	_release=$(balena_api_get_release "${_app_name}" "${_release_version}" "${_api_env}" "${_token}")
	[ "${_release}" = "null " ] && return
	_labels=$(echo "${_release}" | jq -r '.d[0].composition.services[].labels' | tr "\n" " ")
	echo "${_labels}"
}

# Print application ID from application name
# Arguments:
#
# $1: Application name
# $2: Balena target environment
# $3: Balena API token (without it only public apps are accessible)
#
# Result:
#  true in stdout if bootable, false if not
#
# Returns:
#
# 0 if the application is bootable, non-zero otherwise
#
balena_api_is_bootable() {
	local _appName="$1"
	local _apiEnv="$2"
	local _token="${3:-""}"
	[ -z "${_appName}" ] && >&2 echo "Application name is required" && return 1
	local _json=""
	local _admin=${BALENA_ADMIN:-balena_os}
	# Unauthenticated only shows public apps
	if [ -z "${_token}" ]; then
		if [ -f "${HOME}/.balena/token" ]; then
			_token=$(cat "${HOME}/.balena/token")
		fi
	fi
	if [ -n "${_token}" ]; then
		_json=$(${CURL} -XGET "https://api.${_apiEnv}/${TRANSLATION}/application?\$filter=(slug%20eq%20%27${_admin}/${_appName}%27)" -H "Content-Type: application/json" -H "Authorization: Bearer ${_token}")
	else
		_json=$(${CURL} -XGET "https://api.${_apiEnv}/${TRANSLATION}/application?\$filter=(slug%20eq%20%27${_admin}/${_appName}%27)" -H "Content-Type: application/json")
	fi
	__pp_json "${_json}"
	echo "${_json}" | jq -r '.d[0].is_host'
	return 0
}

# Print UUID from application name
# Arguments:
#
# $1: Application name
# $2: Balena target environment
# $3: Balena API token
#
# Result:
# Prints the application UUID or null if it does not exist
balena_api_appUUID_from_appName() {
	local _appName="$1"
	local _apiEnv="$2"
	local _token="${3:-""}"
	[ -z "${_appName}" ] && >&2 echo "Application name is required" && return 1
	local _appUUID=""
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
	_appUUID=$(echo "${_json}" | jq --raw-output '.d[0].uuid')
	__dlog "[${_appName}] Application UUID is ${_appUUID}"
	echo "${_appUUID}"
}

# Fetch the releases at a specific release version
# Arguments:
#
# $1: Public application name
# $2: Balena target environment
# $3: Release version string
#
# Result:
# Prints the release metadata in JSON format
balena_api_fetch_release_json() {
	local _appName="$1"
	local _apiEnv="$2"
	local _version="$3"
	local _json=""
	local _selector=""

	# Get application ID from application name
	_appID=$(balena_api_appID_from_appName "${_appName}" "${_apiEnv}")

	_selector="%20and%20(release_version%20eq%20%27${_version}%27)"
	_json=$(${CURL} -XGET -H "Content-Type: application/json" "https://api.${_apiEnv}/${TRANSLATION}/release?\$filter=(belongs_to__application%20eq%20${_appID})${_selector}")
	__pp_json "${_json}"
	echo "${_json}"
}

# Get release database ID from public application name for a specific release
# Arguments:
#
# $1: Application name
# $2: Release version label
# $3: Balena API environment
#
# Result:
# Prints the release database ID in stdout
__get_dbid_from_app_name() {
	local _appName="${1}"
	local _version="${2}"
	local _apiEnv="${3}"
	local _appID=""
	local _dbID=""

	__dlog "[__get_dbid_from_app_name] Fetching images from ${_appName}, release ${_version}"

	# Fetch release database identifier from application with specified release version
	_dbID=$(balena_api_fetch_release_json "${_appName}" "${_apiEnv}" "${_version}" | jq --raw-output '.d[0].id')
	echo "${_dbID}"
}

# Fetch image location for a specific release
# Arguments:
#
# $1: Application name
# $2: Balena target environment
# $3: BalenaOS version
#
# Result:
# Prints the releases metadata in JSON format
balena_api_fetch_image_json() {
	local _appName="$1"
	local _apiEnv="$2"
	local _version="$3"
	local _json=""
	local _dbID

	_dbID=$(__get_dbid_from_app_name "${_appName}" "${_version}" "${_apiEnv}")
	if [ "${_dbID}" = "null" ]; then
		>&2 echo "[${_appName}] No such release ${_version} in ${_apiEnv}"
		return
	fi

	_json=$(${CURL} -XGET "https://api.${_apiEnv}/${TRANSLATION}/image?%24expand=is_part_of__release(%24expand=release)&%24filter=is_part_of__release/release%20eq%20${_dbID}" -H "Content-Type:application/json")
	__pp_json "${_json}"
	echo "${_json}"
}

# Get image registry location from a public application name for a specific release
# Arguments:
#
# $1: Application name
# $2: Release version label
# $3: Balena API environment
#
# Result:
# Prints the image location in stdout
balena_api_fetch_image_from_app() {
	local _appName="${1}"
	local _version="${2}"
	local _apiEnv="${3}"
	local _imageLocation=""
	local _imageDigest=""
	local _json=""

	_json=$(balena_api_fetch_image_json "${_appName}" "${_apiEnv}" "${_version}")
        [ -z "${_json}" ] && return
	if ! echo "${_json}" | jq -e '.d[0].id' > /dev/null 2>&1; then
		>&2 echo "[${_appName}]: ${_version} not found in ${_apiEnv}"
		return
	fi

	# Get locations for image associated with it
	_imageLocation=$(echo "${_json}" | jq --raw-output '.d[0].is_stored_at__image_location')
	_imageDigest=$(echo "${_json}" | jq  --raw-output '.d[0].content_hash')

	__dlog "Image is ${_imageLocation}@${_imageDigest}"
	echo "${_imageLocation}@${_imageDigest}"
}
