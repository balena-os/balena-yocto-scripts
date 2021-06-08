#!/bin/bash

set -e
[ "${VERBOSE}" = "verbose" ] && set -x

script_name=$(basename "${0}")
automation_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
include_dir="${automation_dir}/include"
build_dir="${automation_dir}/../build"
work_dir=$( cd "${automation_dir}/../../" && pwd )

usage() {
	cat <<EOF
Usage: ${script_name} [OPTIONS]
    -d Device type name
    -a Balena API environment
    -b HostOS block names
    -p Deploy as final version
    -t Balena API token
    -n Registry namespace
    -s Shared build directory
    -v BalenaOS variant (dev | prod)
    -c Balena account (defaults to balena_os)
    -h Display usage
EOF
	exit 0
}

source "${include_dir}/balena-api.inc"
source "${include_dir}/balena-lib.inc"
source "${include_dir}/balena-deploy.inc"

__build_hostos_blocks() {
	local _device_type="${1}"
	local _shared_dir="${2}"
	local _blocks="${3}"
	local _api_env="${4}"
	local _balenaos_account="${5}"
	local _final="${6:-"no"}"
	local _hostos_blocks=""
	local _appname
	local _appnames
	local _version
	local _recipes
	local _packages
	local _bitbake_targets
	local _package_type="${PACKAGE_TYPE:-"ipk"}"

	_api_env="${_api_env:-$(balena_lib_environment)}"

	echo "[INFO] Building ${_device_type} with shared dir ${_shared_dir}"
	if [ -n "${_blocks}" ]; then
		_blocks=$(echo ${_blocks} | tr ":" " ")
		echo "[INFO] Building with the following hostOS block images: ${_blocks}"
		for _block in ${_blocks}; do
			_appname="${_device_type}-${_block}"
			if [ -z "${_appnames}" ]; then
				_appnames="${_appname}"
			else
				_appnames="${_appnames} ${_appname}"
			fi
			_version=$(balena_lib_get_os_version)
			_recipes=$(balena_lib_contract_fetch_composedOf_list "${_block}" "${_device_type}" "${_version}" "sw.recipe.yocto")
			if [ "$?" -ne 0 ] || [ -z "${_recipes}" ]; then
				echo "No packages found in contract"
				exit 1
			fi
			_bitbake_targets="${_bitbake_targets} ${_recipes}"
		done
		_hostos_blocks="--additional-variable HOSTOS_BLOCKS=${appnames}"

		if [ -n "${_bitbake_targets}" ]; then
			_bitbake_targets="${_bitbake_targets} os-release package-index"
			"${build_dir}"/balena-build.sh -d "${_device_type}" -a "${_api_env}" -s "${_shared_dir}" -v "${_variant}"  -i "${_bitbake_targets}"

			# Deploy package feed
			local _deploy_dir="${work_dir}/deploy-jenkins/"
			mkdir -p "${_deploy_dir}"
			balena_deploy_feed "${_deploy_dir}"

			_packages=$(balena_lib_contract_fetch_composedOf_list "${_block}" "${_device_type}" "${_version}" "sw.package.yocto.${_package_type}")
			for _block in ${_blocks}; do
				local _release_version
				_appname="${_device_type}-${_block}"
				balena_build_block "${_appname}" "${_device_type}" "${_packages}" "${_balenaos_account}" "${_api_env}"
				_release_version=$(balena_lib_get_os_version)
				balena_deploy_block "${_appname}"  "${_device_type}" "${_bootable:-0}" "${_image_path:-"${WORKSPACE}/deploy-jenkins/${_appName}-${_release_version}.docker"}"
			done

			# Remove packages folder from deploy directory
			rm -rf "${_deploy_dir}/${_package_type}"
		fi
		echo "${_hostos_blocks}"
	fi
}


main() {
	local _device_type
	local _api_env
	local _token
	local _namespace
	local _shared_dir
	local _hostos_blocks
	local _balenaos_account
	local _final
	local _esr=0
	## Sanity checks
	if [ ${#} -lt 1 ] ; then
		usage
		exit 1
	else
		while getopts "hd:a:t:n:s:b:v:c:ep" c; do
			case "${c}" in
				d) _device_type="${OPTARG}";;
				a) _api_env="${OPTARG}";;
				b) _blocks="${OPTARG}";;
				t) _token="${OPTARG}";;
				n) _namespace="${OPTARG}" ;;
				s) _shared_dir="${OPTARG}" ;;
				v) _variant="${OPTARG}" ;;
				c) _balenaos_account="${OPTARG}" ;;
				e) _esr=1 ;;
				p) _final="yes";;
				h) usage;;
				*) usage;exit 1;;
			esac
		done

		_device_type="${_device_type:-"${MACHINE}"}"
		[ -z "${_device_type}" ] && echo "Device type is required" && exit 1

		_api_env="${_api_env:-$(balena_lib_environment)}"
		_token="${_token:-$(balena_lib_token "${_api_env}")}"
		_shared_dir="${_shared_dir:-"${YOCTO_DIR}"}"
		[ -z "${_shared_dir}" ] && echo "Shared directory is required" && exit 1
		_blocks="${_blocks:-"${hostOSBlocks}"}"
		[ -z "${_blocks}" ] && echo "No block names provided - nothing to do" && exit 1
		[ -n "${_namespace}" ] && echo "Setting dockerhub account to ${_namespace}" && export NAMESPACE=${_namespace}
		_balenaos_account=${_balenaos_account:-balena_os}

		_hostos_blocks=$(__build_hostos_blocks "${_device_type}" "${_shared_dir}" "${_blocks}" "${_api_env}" "${_balenaos_account}" "${_final}")
	fi
}

main "${@}"
