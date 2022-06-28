#!/bin/sh

set -e

VERBOSE=${VERBOSE:-0}
[ "${VERBOSE}" = "verbose" ] && set -x

__dlog() {
	if [ "${DEBUG}" = "1" ]; then
		>&2 echo "${1}"
	fi
}

# Starts a new docker instance
#
# Inputs:
# $1: Data root directory (defaults to /var/lib/docker)
# $2: Base root directory (defaults to /var/run/docker)
# $3: Storage engine directory path (defaults to docker)
# $4: Iptables flag (defaults to true - set to false if running multiple docker daemons)
# $5: Ip masquerading flag (defaults to true - set to false if running multiple docker daemons)
#
# Returns:
#
# 0 on success, other on failure
#
# Outputs:
#
# On success, outputs a string with the docker host socket and the docker PID file path on stdout
# To use it do:
# read -r DOCKER_HOST DOCKER_PIDFILE <<< "$(balena_docker_start))"
#
# The values returned are:
#    DOCKER_HOST="unix://${_rootDir}/docker.sock"
#    DOCKER_PIDFILE="${_rootDir}/docker.pid""
#
# Without a base root dir:
#    DOCKER_HOST="unix:///var/run/docker.sock"
#    DOCKER_PIDFILE="/var/run/docker.pid""
#
balena_docker_start() {
	local _data_dir="${1:-"/var/lib/docker"}"
	local _rootDir="${2:-"/var/run"}"
	local _logfile=${3:-"/dev/null"}
	local _iptables=${4:-"true"}
	local _ipmasq=${5:-"true"}

	[ ! -d "${_data_dir}" ] && mkdir -p "${_data_dir}"
	[ ! -d "${_rootDir}" ] && mkdir -p "${_rootDir}"

	__dlog "[INFO]: Starting docker: data root ${_data_dir}, base root dir ${_rootDir}"
	dockerd --data-root="${_data_dir}" --pidfile="${_rootDir}/docker.pid" --host="unix://${_rootDir}/docker.sock" --iptables="${_iptables}" --ip-masq="${_ipmasq}" --exec-root="${_rootDir}/ds" > "${_logfile}" 2>&1 &
	echo "unix://${_rootDir}/docker.sock ${_rootDir}/docker.pid"
}

# Terminate the dockerd daemon
#
# $1: Exit if failure
# $2: Docker pid file directory (defaults to /var/run/docker)
# $3: Timeout (defaults to 20s)
#
# Returns:
#
# 0 on success, 1 and exit on failure
#
balena_docker_stop() {
	local _fail="${1:-"noexit"}"
	local _pid_file=${2:-"/var/run/docker.pid"}
	local _pname=${3:-"docker"}
	local _timeout=${4:-20}
	local _stime
	local _etime

	__dlog "[INFO] Running balena_docker_stop..."

	# Stop docker gracefully
	__dlog "[INFO] Stopping in container ${_pname}..."
	if [ -f "${_pid_file}" ] && [ -s "${_pid_file}" ] && ps "$(cat "${_pid_file}")" | grep -q "${_pname}"; then
		kill "$(cat "${_pid_file}")"
		# Now wait for it to die
		_stime=$(date +%s)
		_etime=$(date +%s)
		while [ -f "${_pid_file}" ] && [ -s "${_pid_file}" ] && ps "$(cat "${_pid_file}")" | grep -q "${_pname}"; do
			# shellcheck disable=SC2003
			# shellcheck disable=SC2006
			# Bitbake requires this syntax
			if [ "`expr "$_etime" - "$_stime"`" -le "${_timeout}" ]; then
				sleep 1
				_etime=$(date +%s)
			else
				>&2 echo "[ERROR] Timeout while waiting for in container ${_pname} to die."
				exit 1
			fi
		done
	else
		>&2 echo "[WARN] Can't stop ${_pname}."
		>&2 echo "[WARN] Your host might have been left with unreleased resources (ex. loop devices)."
		if [ "${_fail}" = "fail" ]; then
			exit 1
		fi
	fi
}

# Sleep until the dockerd daemon specified by the socker provided is active
#
# Inputs:
# $1: Docker host socket (defaults to unix:///var/run/docker.sock)
#
# Returns
#
# 0 on success, 1 and exit in case of failure
#
balena_docker_wait() {
	local _docker_host=${1:-"unix:///var/run/docker.sock"}
	local _pname="${2:-"docker"}"
	local _stime
	local _etime
	local _timeout=20
	__dlog "[INFO] Waiting for ${_pname} to initialize..."
	_stime=$(date +%s)
	_etime=$(date +%s)
	until DOCKER_HOST=${_docker_host} ${_pname} info >/dev/null 2>&1; do
		# shellcheck disable=SC2003
		# shellcheck disable=SC2006
		# Bitbake requires this syntax
		if [ "`expr "$_etime" - "$_stime"`" -le ${_timeout} ]; then
			sleep 1
			_etime=$(date +%s)
		else
			>&2 echo "[ERROR] Timeout while waiting for ${_pname} to come up."
			exit 1
		fi
	done
	__dlog "[INFO] ${_pname} was initialized."
}

# Retrieves the specified image
#
# Inputs:
#
# $1: Image reference (local file or repository tag)
# $2: Docker socket (defaults to /var/run/docker.sock)
#
# Returns:
#
# 0 on success, other on failure
#
balena_docker_image_retrieve() {
	local _image="${1}"
	local _docker_host="${2:-"${DOCKER_HOST}"}"
	local _image_id
        [ -z "${_docker_host}" ] && _docker_host="unix:///var/run/docker.sock"
	if [ -f "${_image}" ]; then
		if ! _image_id=$(DOCKER_HOST=${_docker_host} docker load -i "${_image}" | grep -o -E '[a-z0-9]{64}'); then
			>&2 echo "_image_retrieve: ${_image} not loaded"
			return 1
		fi
	else
		if ! DOCKER_HOST=${_docker_host} docker pull "${_image}" > /dev/null 2>&1; then
			>&2 echo "_image_retrieve: Failed to pull ${_image}"
			return 1
		fi
		_image_id=$(DOCKER_HOST=${_docker_host} docker images --digests | grep "${_image#*@}" | tr -s " " | cut -d " " -f4)
	fi
	export IMAGEID=${_image_id}
	echo "${_image_id}"
}

# Initialize a compose file in the specified path
#
# Input:
# $1: Path to create the compose file into
__init_compose() {
	local _path="${1}"
	[ -z "${_path}" ] && return
	cat << EOF > "${_path}/docker-compose.yml"
version: '2'
services:
EOF
}

# Add a compose service
#
# Inputs:
# $1: Path to the directory holding the compose file - will be created if needed
# $2: Name of the service to be added
# $3: Image digest for the service
# $4: Image class: fileset, overlay or service (default)
# $5: Image reboot required: 0 (default) or 1
# $6: Image engine type: boot, root or data (default)
# $6: Image is bootable, false (default) or true
#
# Outputs:
#    Compose file in the specified path
#
__add_compose_service() {
	local _path=$1
	local _service_name=$2
	local _image=$3
	local _image_class=$4
	local _image_reboot=$5
	local _image_engine=$6
	local _bootable=$7

	[ -z "${_path}" ] || [ -z "${_service_name}" ] || [ -z "${_image}" ] && return
	_image_class=${_image_class:-"service"}
	_image_reboot=${_image_reboot:-0}
	_image_engine=${_image_engine:-"data"}
	_bootable=${_bootable:-"false"}

	if [ ! -f "${_path}/docker-compose.yml" ]; then
		__init_compose "${_path}"
	fi
	printf "  %s:\n" "${_service_name}" >> "${_path}/docker-compose.yml"
	# Check if image is local (service_name:version)
	if [ "${_image}" != "${_service_name}:*" ]; then
		printf "    image: %s\n" "${_image}" >> "${_path}/docker-compose.yml"
	else
		printf "    build: %s\n" "${_service_name}" >> "${_path}/docker-compose.yml"
		mkdir "${_path}/${_service_name}"
		echo "FROM ${_image}" > "${_path}/${_service_name}/Dockerfile"
	fi
	printf "    labels:\n" >> "${_path}/docker-compose.yml"
	if [ -n "${_image_class}" ]; then
		printf "      %s: %s\n" \""${BALENA_HOSTOS_BLOCK_CLASS}"\" \""${_image_class}"\" >> "${_path}/docker-compose.yml"
	fi
	if [ "${_image_reboot}" = "1" ]; then
		printf "      %s: '1'\n" \""${BALENA_HOSTOS_BLOCK_REQUIRES_REBOOT}"\" >> "${_path}/docker-compose.yml"
	fi
	if [ -n "${_image_engine}" ]; then
		printf "      %s: %s\n" \""${BALENA_HOSTOS_BLOCK_STORE}"\" \""${_image_engine}"\" >> "${_path}/docker-compose.yml"
	fi
	if [ "${_bootable}" = "true" ]; then
		printf "      %s: %s\n" \""${BALENA_HOSTOS_BLOCK_BOOTABLE}"\" \""${_bootable}"\" >> "${_path}/docker-compose.yml"
	fi
}

# Creates a compose file
#
# Inputs:
# $1: Device type to build for
# $2: Balena API environment (default to balena-cloud.com)
# $3: BalenaOS version - defaults to current device repository tag
# $4: BalenaOS token
# $5: HostOS blocks - defaults to hostapp block
# $6: Working dir - if not provided uses a temporary directory
#
# Outputs:
#    Path where the compose file is created
#
balena_docker_create_compose_file() {
	local _device_type="$1"
	local _apiEnv="$2"
	local _version="$3"
	local _token="$4"
	local _blocks="${5:-${_device_type}}"
	local _work_dir="${6:-$(mktemp -d)}"
	local _block_image
	local _class
	local _store
	local _reboot_required
	local _block
	local _image_id
	local _local_image
	local _bootable
	local _release_path="${_work_dir}/release"

	[ -z "${_device_type}" ] && return
	_version=${_version:-$(balena_lib_get_os_version)}
	_apiEnv=${_apiEnv:-"balena-cloud.com"}

	mkdir -p "${_release_path}"
	[ -z "${_blocks}" ] && >&2 echo "Blocks are required" && return 1
	for _block in ${_blocks}; do
		# Try to find a hostapp container image first
		_local_image=$(readlink --canonicalize $(find "${_work_dir}" -name "balena-image-${_block}.docker") || true)
		if [ -z "${_local_image}" ]; then
			# If not, try to find a block container image
			_local_image=$(readlink --canonicalize $(find "${_work_dir}" -name "${_block}-${_version}.docker") || true)
		fi
		if [ -n "${_local_image}" ]; then
			_image_id=$(balena_docker_image_retrieve "${_local_image}")
			docker tag "${_image_id}" "${_block}:${_version}"
			_block_image="${_block}:${_version}"
		else
			_block_image=$(balena_api_fetch_image_from_app "${_block}" "${_version}" "${_apiEnv}")
			if [ -z "${_block_image}" ] || [ "${_block_image}" = "" ]; then
				>&2 echo "[${_block}] No such image for ${_version} in ${_apiEnv}"
				continue
			fi
			_image_id=$(balena_docker_image_retrieve "${_block_image}")
		fi
		if [ -z "${_image_id}" ] || [ "${_image_id}" = "" ]; then
			>&2 echo "[${_block}] Could not find image for ${_version} in ${_apiEnv}"
			return 1
		fi
		# Container images created by importing a tarball and saving (like the Yocto docker image class does) do not contain labels
		# Hence, if no labels are found default to hostapp values, class service, root store and bootable.
		_class=$(balena_lib_get_label_from_image "${_image_id}" "${BALENA_HOSTOS_BLOCK_CLASS}")
		[ -z "${_class}" ] && class="service"
		_store=$(balena_lib_get_label_from_image "${_image_id}" "${BALENA_HOSTOS_BLOCK_STORE}")
		[ -z "${_store}" ] && _store="root"
		_reboot_required=$(balena_lib_get_label_from_image "${_image_id}" "${BALENA_HOSTOS_BLOCK_REQUIRES_REBOOT}")
		[ -z "${_reboot_required}" ] && _reboot_required="1"
		_bootable=$(balena_api_is_bootable "${_block}" "${_apiEnv}" "${_token}")
		__add_compose_service "${_release_path}" "${_block}" "${_block_image}" "${_class}" "${_reboot_required}" "${_store}" "${_bootable}"
	done
	echo "${_release_path}"
}
