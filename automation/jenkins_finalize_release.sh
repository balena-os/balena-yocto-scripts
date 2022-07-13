#!/bin/bash
set -e

VERBOSE=${VERBOSE:-0}
[ "${VERBOSE}" = "verbose" ] && set -x

readonly script_name=$(basename "${0}")
readonly script_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
readonly script_file="${script_dir}/$(basename "${BASH_SOURCE[0]}")"
readonly script_base="$(basename ${script_file} .sh)"

usage() {
	cat <<EOF
Usage: ${script_name} [OPTIONS]
    -v balenaOS version to finalize
	-m Device type
	-e Deploy to environment (defaults to production)
    -h Display usage
    -d Verbose output
EOF
}

error() {
	printf "${red}!!! %s${reset}\\n" "${*}" 1>&2
}

_api_env=$(balena_lib_environment)
_esr="false"
main() {
	## Sanity checks
	if [ ${#} -eq 0 ] ; then
		usage
		exit 1
	else
		while getopts "hv:e:m:d" c; do
			case "${c}" in
				v) _version="${OPTARG:-}";;
				e) _api_env="${OPTARG:-}";;
				m) _device_type="${OPTARG:-}";;
				h) usage;;
				d) VERBOSE="verbose";;
				*) usage;exit 1;;
			esac
		done
	[ -z "${_version}" ] && echo "balenaOS version to finalize is required" && exit 1
	[ -z "${_device_type}" ] && echo "Device type is required" && exit 1
	_slug=$(balena_lib_get_slug "${_device_type}")
	_fleet="${BALENAOS_ORG}/${_slug}"
	_token=$(balena_lib_token "${_api_env}")
	_releaseID=$(balena_api_get_draft_releaseID "${_fleet}" "${_version}" "${_api_env}" "${_token}")
	if balena_lib_is_esr "${_version}"; then
		_esr="true"
	fi
	balena_lib_release_finalize "${_releaseID}" "${_fleet}" "${_api_env}" "${_token}" "${_esr}"
	fi
}

main "${@}"
