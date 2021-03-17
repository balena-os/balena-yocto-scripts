#!/bin/bash
set -e

script_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
device_dir=$(realpath "${script_dir}/../../")
BALENA_YOCTO_SCRIPTS_REVISION=$(cd "${script_dir}" && git rev-parse --short HEAD)

# Return the latest tag of the device repository
balena_lib_get_os_version() {
	pushd "${device_dir}" > /dev/null 2>&1 || return
	_version=$(git describe --abbrev=0)
	popd > /dev/null 2>&1 || return
	echo "${_version#v*}"
}

# Return the latest tag of the meta-balena repository
balena_lib_get_meta_balena_version() {
	pushd "${device_dir}/layers/meta-balena" > /dev/null 2>&1 || return
	_version=$(git describe --abbrev=0)
	popd > /dev/null 2>&1 || return
	echo "${_version#v*}"
}

# Pull a helper image building a matching version if required
# Inputs:
# $1: Dockerfile name
balena_lib_docker_pull_helper_image() {
	local _dockerfile_name="$1"
	local _image_name=""
	local _image_prefix=""
	local _retvalue="$2"
	_im
        age_name="${_dockerfile_name%".template"}"
	_image_name="${_image_name#"Dockerfile_"}"
	case ${_dockerfile_name} in
		*template)
			_image_prefix="${MACHINE}-"
			DEVICE_ARCH=$(jq --raw-output '.arch' "$WORKSPACE/$MACHINE.json")
			export DEVICE_ARCH
			DEVICE_TYPE=${MACHINE}
			export DEVICE_TYPE
			;;
	esac

	if ! docker pull "${NAMESPACE}"/"${_image_prefix}""${_image_name}":"${BALENA_YOCTO_SCRIPTS_REVISION}"; then
		JOB_NAME="${JOB_NAME}" DOCKERFILES="${_dockerfile_name}" "${script_dir}/jenkins_build-containers.sh"
	fi
	eval "$_retvalue"='${BALENA_YOCTO_SCRIPTS_REVISION}'
}

# Output the partition table type for the specified device type
#
# Inputs:
#
# $1: Device type name
#
# Returns:
# 0 on success and outputs partition table type in stdout
# 1 on error
#
balena_lib_contract_get_partition_table () {
    local _device_type="${1}"
    local _contract

    if [ _contract=$(__find_contract_by_slug "${_device_type}") ]; then
        echo $(echo "${_contract}" | jq -r '.data.storage.partitionTableType')
        return 0
    fi
    return 1
}

# Output the storage units for the specified device type
#
# Inputs:
#
# $1: Device type name
#
# Returns:
# 0 on success and outputs storage units in stdout
# 1 on error
#
balena_lib_contract_get_units () {
    local _device_type="${1}"
    local _contract

    if [ _contract=$(__find_contract_by_slug "${_device_type}") ]; then
        echo $(echo "${_contract}" | jq -r '.data.storage.units')
        return 0
    fi
    return 1
}

# Output the details for the specified partition name and device type
#
# Inputs:
#
# $1: Device type name
# $2: Partition name
#
# Returns:
# 0 on success and outputs partition details json in stdout
# 1 on error
#
balena_lib_contract_get_part () {
    local _device_type="${1}"
    local _part_name="${2}"
    local _contract

    if [ _contract=$(__find_contract_by_slug "${_device_type}") ]; then
        echo $(jq -r ".data.storage.partitions[${_part_name}]")
        return 0
    fi
    return 1
}

# Output a space separates list of partition names
#
# Inputs:
#
# $1: Device type name
#
# Returns:
# 0 on success and outputs a space separated list of partition names in stdout
# 1 on error
#
balena_lib_contract_get_partitions_list () {
    local _device_type="${1}"
    local _contract

    if [ _contract=$(__find_contract_by_slug "${_device_type}") ]; then
        echo $(echo "${_contract}" | jq -r '.data.storage.partitions | keys[]' | tr "\n" " ")
        return 0
    fi
    return 1
}

# Output the total image size
#
# Inputs:
#
# $1: Device type name
#
# Returns:
# 0 on success and outputs a the total image size in stdout
# 1 on error
#
balena_lib_contract_get_image_size () {
    local _device_type="${1}"
    local _contract
    local _sizes
    local _total_size=0

    if [ _contract=$(__find_contract_by_slug "${_device_type}") ]; then
        _sizes=$(echo "${_contract}" | jq -r '.data.storage.partitions[].size' | tr "\n" " ")
        for size in ${sizes}; do
            _total_size=$(( _total_size + size ))
        done
        echo "${_total_size}"
        return 0
    fi
    return 1
}

# Find a contract path by slug name
#
# Inputs:
# $1: Slug name to search for
#
# Returns:
#   Contract path in stdout if successful
__find_contract_by_slug() {
	local _tslug="${1}"
	local _contracts
	local _slug

	_contracts=$(find "${device_dir}/contracts/" -name "contract.json" -print 2>/dev/null)
	for contract in ${_contracts}; do
		_slug=$(jq --raw-output .slug < "${contract}")
		if [ "${_slug}" = "${_tslug}" ]; then
			echo "${contract}"
			return 0
		fi
	done
	>&2 echo "Contract not found for ${_tslug}"
	return 1
}

# Get a package list from an image name
#
# Inputs:
# $1: Contract Slug name to search for
# $2: Device type
# $3: OS version (optional)
#
# Returns:
#   Package list in stdout if successful
balena_lib_fetch_package_list() {
	local _slug="${1}"
	local _device_type=${2}
	local _version=${3}
	local _contract
	local _device_types_depends
	local _version
	local _sw_package_name
	local _package_contract
	local _packages
	_contract=$(__find_contract_by_slug "${_slug}")
	if [ -z "${_contract}" ]; then
		>&2 "${_slug}: No contract found"
		return 1
	fi
	if [ -z "${_version}" ]; then
		_version=$(balena_lib_get_os_version)
	fi
	# Check device type compatibility
	_device_types_depends=$(jq --raw-output '.requires[].anyOf[] | select(.type == "hw.device-type") | .slug' "${_contract}")
	local _found=0
	for dt in ${_device_types_depends}; do
		if [ "${dt}" = "${_device_type}" ]; then
			_found=1
			break
		fi
	done
	[ "${_found}" = "0" ] && >&2 echo "${_slug}: Not compatible device type: ${_device_type}"  && return 1
	_sw_package_name=$(jq --raw-output '.requires[].allOf[] | select(.type == "sw.package") | .slug' "${_contract}")
	_package_contract=$(__find_contract_by_slug "${_sw_package_name}")
	# Check OS compatibility
	_version_depends=$(jq --raw-output '.requires[].allOf[] | select(.type == "sw.os") | select(.slug == "balenaos") | .version' "${_contract}")
	for os in ${_version_depends}; do
		if ! "${script_dir}/semver2.sh" "${os}" "${_version}" 2&>/dev/null; then
			>&2 echo "${_slug}: OS version not compatible"
			return 1
		fi
	done
	_packages=$(jq --raw-output '.composedOf[] | .slug ' "${_package_contract}" | tr "\n" " ")
	echo "${_packages}"
}

# Outputs to Balena environment according to Jenkins "deployTo" environment variables
balena_lib_environment() {
	local _api_env
	if [ -n "${deployTo}" ]; then
		if [ "${deployTo}" = "staging" ]; then
			_api_env="balena-staging.com"
		elif [ "${deployTo}" = "production" ]; then
			_api_env="balena-cloud.com"
		fi
	else
		echo "An deployTo target environment is required"
		return
	fi
	export BALENARC_BALENA_URL=${_api_env}
	echo "${_api_env}"
}

# Output the Balena environment token according to set environment
balena_lib_token() {
	local _api_env
	[ -z "${_api_env}" ] && _api_env=$(balena_lib_environment)
	if [ "${_api_env}" = "balena-staging.com" ]; then
		if [ -n "${BALENAOS_STAGING_TOKEN}" ]; then
			_token="${BALENAOS_STAGING_TOKEN}"
		else
			return
		fi
	elif [ "${_api_env}" = "balena-cloud.com" ]; then
		if [ -n "${BALENAOS_PRODUCTION_TOKEN}" ]; then
			_token="${BALENAOS_PRODUCTION_TOKEN}"
		else
			return
		fi
	fi
	echo "${_token}"
}

# Logins to Balena cloud
balena_lib_login() {
	local _api_env=$1
	local _token=$2

	[ -z "${_api_env}" ] && _api_env=$(balena_enviroment)
	if [ -z "${_api_env}" ]; then
		echo "A Balena environment is required"
		return
	fi
	[ -z "${_token}" ] && _token=$(balena_lib_token)
	if [ -z "${_token}" ]; then
		echo "A Balena token is required"
		return
	fi
	BALENARC_BALENA_URL=${_api_env} balena login --token "${_token}"
}
