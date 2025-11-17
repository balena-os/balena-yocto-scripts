#!/usr/bin/env bash

DOCKER="${DOCKER:-"docker"}"

script_name=$(basename "${0}")
script_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
work_dir="$( cd "${script_dir}/../.." && pwd )"

usage() {
	cat <<EOF
Usage: ${script_name} [OPTIONS]
    -d Device type name (required)
    -s Shared build directory (required)
    -c Base64-encoded certificate to verify (required)
    -h Display usage
EOF
	exit 0
}

source "${script_dir}/../automation/include/balena-lib.inc"

__check_docker() {
	if ! "${DOCKER}" info > /dev/null 2>&1; then
		return 1
	fi
	return 0
}

main() {
	local _device_type
	local _shared_dir
	local _cert_base64

	## Sanity checks
	if [ ${#} -lt 1 ] ; then
		usage
		exit 1
	else
		while getopts "hd:s:c:a:" c; do
			case "${c}" in
				d) _device_type="${OPTARG}";;
				a) _api_env="${OPTARG}";;
				s) _shared_dir="${OPTARG}" ;;
				c) _cert_base64="${OPTARG}" ;;
				h) usage;;
				*) usage;exit 1;;
			esac
		done

		_device_type="${_device_type:-"${MACHINE}"}"
		[ -z "${_device_type}" ] && echo "Device type is required" && exit 1
		[ -z "${_shared_dir}" ] && echo "Shared directory is required" && exit 1
		# [ -z "${_cert_base64}" ] && echo "Certificate (base64) is required" && exit 1

		_api_env="${_api_env:-$(balena_lib_environment)}"
		_dl_dir="${_shared_dir}/shared-downloads"
		_sstate_dir="${_shared_dir}/${_device_type}/sstate"

		if ! __check_docker; then
			echo "Docker needs to be installed"
			exit 1
		fi

		# Pull the helper image (same as balena-build.sh)
		if ! balena_lib_docker_pull_helper_image "${HELPER_IMAGE_REPO}" "" "yocto-build-env" helper_image_id; then
			echo "Failed to pull helper image"
			exit 1
		fi

		# Set up SSH_AUTH_SOCK (same as balena-build.sh)
		[ -z "${SSH_AUTH_SOCK}" ] && echo "No SSH_AUTH_SOCK in environment - private repositories won't be accessible" && SSH_AUTH_SOCK="/dev/null"

		# Run in the same container environment as the build
		# Replicate the exact Docker run from balena-build.sh, but call our script instead
		${DOCKER} run --rm \
			-v "${work_dir}":/work \
			-v "${_dl_dir}":/yocto/shared-downloads \
			-v "${_sstate_dir}":/yocto/shared-sstate \
			-v "${SSH_AUTH_SOCK}":/tmp/ssh-agent \
			-e BUILDER_UID="$(id -u)" \
			-e VERBOSE="${VERBOSE}" \
			-e BUILDER_GID="$(id -g)" \
			--name "verify-kernel-keys-$$" \
			--privileged \
			"${helper_image_id}" \
			/verify_kernel_keys.sh \
			"${_cert_base64}" || {
				echo "Failed to verify kernel signing keys"
				exit 1
			}
	fi
}

main "${@}"

