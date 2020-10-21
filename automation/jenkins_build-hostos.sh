#!/bin/bash

set -e

script_name=$(basename "${0}")
script_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

[ -z "${MACHINE}" ] && echo "Device type is required" && exit 1

source "${script_dir}/balena-api.inc"
source "${script_dir}/balena-lib.inc"

NAMESPACE="${NAMESPACE:-resin}"
PACKAGE_TYPE=${PACKAGE_TYPE:-ipk}

API_ENV=$(balena_lib_environment)
BALENA_TOKEN=$(balena_lib_token)

[ -z "${API_ENV}" ] && echo "Target environment is required" && exit 1
[ -z "${BALENA_TOKEN}" ] && echo "API or session token is required" && exit 1

if [ "${deploy}" = "no" ]; then
	echo "Deploy is set to no - bailing out"
	exit 1
fi

echo "[INFO] Building ${MACHINE} with shared dir ${YOCTO_DIR}"
HOSTOS_BLOCKS=""
if [ -n "${hostOSBlocks}" ]; then
	blocks=$(echo ${hostOSBlocks} | tr ":" " ")
	echo "[INFO] Building with the following hostOS block images: ${blocks}"
	for block in ${blocks}; do
		appname="${MACHINE}-${block}"
		if [ -z "${appnames}" ]; then
			appnames="${appname}"
		else
			appnames="${appnames} ${appname}"
		fi
		HOSTOS_BLOCKS="--additional-variable HOSTOS_BLOCKS=${appnames}"
		_release_version=$(balena_lib_get_os_version)
		if balena_api_get_release "${MACHINE}-${block}" "${_release_version}" "${API_ENV}"; then
			echo "[INFO] Release ${_release_version} already exists for ${block}"
			continue
		fi
		PACKAGES=$(balena_lib_fetch_package_list "${block}" "${MACHINE}")
		if [ "$?" -ne 0 ] || [ -z "${PACKAGES}" ]; then
			echo "No packages found in contract"
			exit 1
		fi
		BITBAKE_TARGETS="--bitbake-target ${PACKAGES} os-release package-index"
	done

	if [ -n "${PACKAGES}" ]; then
		"${script_dir}"/jenkins_build.sh -m "${MACHINE}" --continue --package-feed --shared-dir "${YOCTO_DIR}" ${BITBAKE_TARGETS}

		for block in ${blocks}; do
			appname="${MACHINE}-${block}"
			balena_deploy_block "${appname}"
		done
		# Remove packages folder from deploy directory
		rm -rf "${WORKSPACE}/deploy-jenkins/${PACKAGE_TYPE}"
	fi
fi

# Building and deploy core hostapp
"${script_dir}"/jenkins_build.sh -m "${MACHINE}" --shared-dir "${YOCTO_DIR}" --build-flavor "${buildFlavor}" --additional-variable BALENA_TOKEN="${BALENA_TOKEN}" --additional-variable BALENA_API_ENV="${API_ENV}" --bitbake-task image_docker --bitbake-target balena-image
_image_path=$(readlink --canonicalize $WORKSPACE/build/tmp/deploy/images/$MACHINE/balena-image-$MACHINE.docker)
balena_deploy_hostapp "${_image_path}" "${API_ENV}" "${BALENA_TOKEN}"

balena_deploy_hostos "${MACHINE}-hostos" "${MACHINE}" "${API_ENV}" "${hostOSBlocks}" "${BALENA_TOKEN}"

# Build target images
"${script_dir}"/jenkins_build.sh -m "${MACHINE}" --preserve-build --shared-dir "${YOCTO_DIR}" --build-flavor "${buildFlavor}" ${HOSTOS_BLOCKS} --additional-variable BALENA_TOKEN="${BALENA_TOKEN}" --additional-variable BALENA_API_ENV="${API_ENV}"
