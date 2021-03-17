#!/bin/bash
set -e

include_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
device_dir=$( if cat /proc/self/cgroup | grep -q docker; then if [ -d "/work" ]; then cd "/work" && pwd; fi; else cd "${include_dir}/../../.." && pwd; fi )
BALENA_YOCTO_SCRIPTS_REVISION=$(cd "${include_dir}" && git rev-parse --short=7 HEAD || true)

NAMESPACE="${NAMESPACE:-"resin"}"

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
	_image_name="${_dockerfile_name%".template"}"
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
		JOB_NAME="${JOB_NAME}" DOCKERFILES="${_dockerfile_name}" "${include_dir}/../jenkins_build-containers.sh"
	fi
	eval "$_retvalue"='${BALENA_YOCTO_SCRIPTS_REVISION}'
}

# Remove all versions of a  helper image
# Inputs:
# $1: Image name
#
balena_lib_docker_remove_helper_images() {
	local _image_name="${1}"
	local _image_ids
	local _id
	_image_ids=$(docker images "${NAMESPACE}/${_image_name}" --format "{{.ID}}")
	for _id in ${_image_ids}; do
		docker rmi -f "${_id}" || true
	done
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
	local _slug="${1}"
	local _contract

	_contract=$(__find_contract_by_slug "${_slug}")
	if [ "$?" == "0" ]; then
		echo $(cat "${_contract}" | jq -r '.partitionTable.type')
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
	local _slug="${1}"
	local _contract

	_contract=$(__find_contract_by_slug "${_slug}")
	if [ "$?" == "0" ]; then
		echo $(cat "${_contract}" | jq -r '.partitionTable.units')
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
	local _slug="${1}"
	local _part_name="${2}"
	local _contract

	_contract=$(__find_contract_by_slug "${_slug}")
	if [ "$?" == "0" ]; then
		echo $(cat "${_contract}" | jq -r '.partitionTable.partitions["'${_part_name}'"]')
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
	local _slug="${1}"
	local _contract

	_contract=$(__find_contract_by_slug "${_slug}")
	if [ "$?" == "0" ]; then
		echo "$(cat "${_contract}" | jq -r '.partitionTable.partitions | keys_unsorted[]' | tr "\n" " ")"
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
	local _slug="${1}"
	local _contract
	local _sizes
	local _total_size
	local _alignment
	local _alignments

	_contract=$(__find_contract_by_slug "${_slug}")
	if [ "$?" == "0" ]; then
		_total_size=0
		_sizes=$(cat "${_contract}" | jq -r '.partitionTable.partitions[].size' | tr "\n" " ")
		for size in ${_sizes}; do
			_total_size=$(( _total_size + size ))
		done
		_alignments=$(cat "${_contract}" | jq -r '.partitionTable.partitions[].alignment' | tr "\n" " ")
		for _alignment in ${_alignments}; do
			_total_size=$(( _total_size + _alignment ))
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

# Check contract compatibility with a given device type
#
# $1: Contract slug
# $2: Device type name
#
# Output
#
# Returns 0 if compatible 1 if not
balena_lib_contract_is_device_compatible() {
	local _slug="${1}"
	local _device_type="${2}"
	local _contracts
	local _device_types_depends
	local _dt
	local _found=0

	_contract=$(__find_contract_by_slug "${_slug}")
	if [ -z "${_contract}" ]; then
		>&2 "${_slug}: No contract found"
		return 1
	fi

	_device_types_depends=$(jq --raw-output '.requires[].anyOf[] | select(.type == "hw.device-type") | .slug' "${_contract}")
	for _dt in ${_device_types_depends}; do
		if [ "${_dt}" = "${_device_type}" ]; then
			_found=1
			break
		fi
	done
	if [ "${_found}" = "0" ]; then
		>&2 echo "${_slug}: Not compatible device type: ${_device_type}"
		return 1
	fi
	return 0
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

	# Check device type compatibility
	if ! balena_lib_contract_is_device_compatible "${_slug}" "${_device_type}"; then
		>&2 echo "Device type not compatible"
		return
	fi

	if [ -z "${_version}" ]; then
		_version=$(balena_lib_get_os_version)
	fi
	_contract=$(__find_contract_by_slug "${_slug}")
	if [ -z "${_contract}" ]; then
		>&2 "${_slug}: No contract found"
		return 1
	fi

	_sw_package_name=$(jq --raw-output '.requires[].allOf[] | select(.type == "sw.package") | .slug' "${_contract}")
	_package_contract=$(__find_contract_by_slug "${_sw_package_name}")
	# Check OS compatibility
	_version_depends=$(jq --raw-output '.requires[].allOf[] | select(.type == "sw.os") | select(.slug == "balenaos") | .version' "${_contract}")
	for os in ${_version_depends}; do
		if ! "${include_dir}/semver2.sh" "${os}" "${_version}" 2&>/dev/null; then
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
		>&2 echo "[balena_lib_environment]: Defaulting to balena-cloud.com"
		_api_env="balena-cloud.com"
	fi
	export BALENARC_BALENA_URL=${_api_env}
	echo "${_api_env}"
}

# Output the Balena environment token according to set environment
balena_lib_token() {
	local _api_env="${1}"
	[ -z "${_api_env}" ] && _api_env=$(balena_lib_environment)
	if [ "${_api_env}" = "balena-staging.com" ]; then
		if [ -n "${BALENAOS_STAGING_TOKEN}" ]; then
			_token="${BALENAOS_STAGING_TOKEN}"
		fi
	elif [ "${_api_env}" = "balena-cloud.com" ]; then
		if [ -n "${BALENAOS_PRODUCTION_TOKEN}" ]; then
			_token="${BALENAOS_PRODUCTION_TOKEN}"
		fi
	fi
	if [ -z "${_token}" ]; then
		if [ -f "${HOME}/.balena/token" ]; then
			_token="$(cat "${HOME}/.balena/token")"
		else
			return
		fi
	fi
	echo "${_token}"
}

# Logins to Balena cloud
#
# Inputs:
#
# $1: Balena API environment
# $2: Balena API token
# $3: Force flag to override ~/.balena/token
#
# Returns:
# 0 if successful or 1 if failed
#
balena_lib_login() {
	local _api_env=$1
	local _token=$2
	local _force=$3

	[ -z "${_api_env}" ] && _api_env=$(balena_lib_environment)
	if [ -z "${_api_env}" ]; then
		echo "A Balena environment is required"
		return 1
	fi
	if [ -z "${_token}" ]; then
		if [ ! -f "${HOME}/.balena/token" ] || [ -n "${_force}" ];then
			_token=$(balena_lib_token "${_api_env}")
			if [ -z "${_token}" ]; then
				echo "A Balena token is required"
				return 1
			fi
		else
			>&2 echo "[balena_lib_login]: Using existing login"
			return 0
		fi
	fi
	BALENARC_BALENA_URL=${_api_env} balena login --token "${_token}"
	return 0
}

# Login to dockerhub
#
# Inputs:
# $1: Dockerhub username
# $2: Dockerhub password
#
balena_lib_dockerhub_login() {
	local _user="${1}"
	local _pwd="${2}"

	if [ -z "${_user}" ]; then
		if [ -n "${JOB_NAME}" ]; then
			_user="${DOCKERHUB_USER:-"balenadevices"}"
			echo "Login to docker as ${_user}"
		fi
	fi

	if [ -z "${_pwd}" ]; then
		if [ -n "${JOB_NAME}" ]; then
			_pwd=${DOCKERHUB_PWD:-"${balenadevicesDockerhubPassword}"}
		fi
	fi

	# Fallback to interactive or cached credentials
	docker login -u "${_user}" -p "${_pwd}"
}

# Retrieve slug from device type JSON file
#
# Inputs:
# $1: Device type name
#
# Returns:
# 0 on success 1 on failure
#
# Outputs:
# slug in stdout if successful, device type name in stdout if failed
#
balena_lib_get_slug() {
	local _device_type="${1}"
	local _slug
	local _device_type_json="${device_dir}/${_device_type}.json"

	if [ ! -f "${_device_type_json}" ]; then
		>&2 echo "[balena_lib_get_slug]: Device type JSON not found - assuming equal to device type"
		echo "${_device_type}"
		return 1
	fi

	_slug=$(jq --raw-output '.slug' "${_device_type_json}")
	echo "${_slug}"
	return 0
}

# Retrieve deploy artifact from device type JSON file
#
# Inputs:
# $1: Device type name
#
# Returns:
# 0 on success 1 on failure
#
# Outputs:
# deploy artifact in stdout if successful
#
balena_lib_get_deploy_artifact() {
	local _device_type="${1}"
	local _artifact
	local _device_type_json="${device_dir}/${_device_type}.json"

	if [ ! -f "${_device_type_json}" ]; then
		>&2 echo "[balena_lib_get_deploy_artifact]: Device type JSON not found"
		return 1
	fi

	_artifact=$(jq --raw-output '.yocto.deployArtifact' "${_device_type_json}")
	echo "${_artifact}"
	return 0
}

# Retrieve device state from device type JSON file
#
# Inputs:
# $1: Device type name
#
# Returns:
# 0 on success 1 on failure
#
# Outputs:
# device state in stdout if successful
#
balena_lib_get_dt_state() {
	local _device_type="${1}"
	local _state
	local _device_type_json="${device_dir}/${_device_type}.json"

	if [ ! -f "${_device_type_json}" ]; then
		>&2 echo "[balena_lib_get_slug]: Device type JSON not found"
		return 1
	fi

	_state=$(jq --raw-output '.state' "${_device_type_json}")
	echo "${_state}"
	return 0
}

# Provide a contract slug given a Yocto machine type
#
# Inputs:
# $1: Yocto machine
#
# Output:
# Contract slug in srdout
#
balena_lib_resolve_aliases() {
	local _device_type="${1}"

	case "${_device_type}" in
		"genericx86-64") echo "intel-nuc" ;;
		"raspberrypi") echo "raspberry-pi" ;;
		"raspberrypi2") echo "raspberry-pi2" ;;
		"beaglebone") echo "beaglebone-black" ;;
		"edison") echo "intel-edison" ;;
		*) echo "${_device_type}";;
	esac
}

# Retrieve device architecture from device type JSON file
#
# Inputs:
# $1: Device type name
#
# Returns:
# 0 on success 1 on failure
#
# Outputs:
# device architecture in stdout if successful
#
balena_lib_get_dt_arch() {
	local _device_type="${1}"
	local _arch
	local _device_type_json="${device_dir}/${_device_type}.json"

	if [ ! -f "${_device_type_json}" ]; then
		>&2 echo "[balena_lib_get_slug]: Device type JSON not found"
		return 1
	fi

	_arch=$(jq --raw-output '.arch' "${_device_type_json}")
	echo "${_arch}"
	return 0
}

# Fetch image label
#
# Inputs:
# $1: Image ID
# $2: Label key to look for
#
#
# Output:
#  Label value in stdout or null
#
balena_lib_get_label_from_image() {
	local _image_id="${1}"
	local _label="${2}"
	local _value

	_value=$(docker inspect "${_image_id}" | jq -r '.[].Config.Labels["'"${_label}"'"]')
	echo "${_value}"
}
