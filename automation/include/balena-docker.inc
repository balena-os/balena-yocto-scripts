#!/bin/sh

set -e

DOCKER_TIMEOUT=20 # Wait 20 seconds for docker to start

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
	dockerd --data-root="${_data_dir}" --pidfile="${_rootDir}/docker.pid" --host="unix://${_rootDir}/docker.sock" --iptables=${_iptables} --ip-masq=${_ipmasq} --exec-root="${_rootDir}/ds" > "${_logfile}" 2>&1 &
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
