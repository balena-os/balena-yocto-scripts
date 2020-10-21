#!/bin/bash

set -e

script_name=$(basename "${0}")
script_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

[ -z "${MACHINE}" ] && echo "Device type is required" && exit 1
[ -z "${HOSTEXT_IMAGES}" ] && echo "Hostapp extension names are required" && exit 1

export PACKAGE_TYPE=${PACKAGE_TYPE:-ipk}

get_package_list() {
	local _hostext_name
	local _json
	_hostext_name="$1"
	_json="$WORKSPACE/balenaos-extensions/${_hostext_name}.json"
        if [ -z "${_json}" ]; then
	      >&2 echo "[WARN]: Extensions definition file not found"
	      return
        fi
	_appname=$(jq --raw-output '.name' "${_json}")
	if [ -z "${_appname}" ]; then
		>&2 echo "[WARN]: Extension name not defined"
		return
	fi
	if [ "${_appname}" != "${_hostext_name}" ]; then
		>&2 echo "[WARN]: Mismatch: Looking for ${_hostext_name} but found ${_appname} in extensions definition file."
		return
	fi
	_os_versions=$(jq --raw-output '."os-versions"[]' "${_json}")
	for version in ${_os_versions}; do
		local _os_version
		# Extension manifest uses untranslated version
		_os_version=$(cat "${WORKSPACE}/deploy-jenkins/VERSION_HOSTOS")
		if [ "${version}" = "${_os_version}" ] || [ "${version}" = "any" ]; then
			PACKAGES=$(jq --raw-output '.contents.packages[]' "${_json}" | tr "\n" " ")
			break
		fi
	done
	[ -z "${PACKAGES}" ] && >&2 echo "[ERROR]: ${_hostext_name} extension not compatible with version ${_os_version}" && return
	echo "${PACKAGES}"
}

if [ "$deployTo" = "production" ]; then
	BALENA_TOKEN="${BALENAOS_PRODUCTION_TOKEN}"
	API_ENV=balena-cloud.com
elif [ "$deployTo" = "staging" ]; then
	BALENA_TOKEN="${BALENAOS_STAGING_TOKEN}"
	API_ENV=balena-staging.com
fi
[ -z "${API_ENV}" ] && echo "Target environment is required" && exit 1
[ -z "${BALENA_TOKEN}" ] && echo "API or session token is required" && exit 1

if [ "${deployHostappExtension}" = "yes" ]; then
	# Build the package feed for the specified packages
	for extension in ${HOSTEXT_IMAGES}; do
		EXTENSIONS="${EXTENSIONS} --extension ${extension}"
	done
	"${script_dir}"/jenkins-package-feed.sh -m "${MACHINE}" --shared-dir "${YOCTO_DIR}" ${EXTENSIONS}

	if [ -e "${WORKSPACE}/deploy-jenkins/VERSION_HOSTOS" ]; then
		# Translate OS version to register compatible format
		export VERSION_HOSTOS=$(cat "${WORKSPACE}/deploy-jenkins/VERSION_HOSTOS" | tr "+" "_")
	fi

	# Build the hostapp extension from those packages
	for hostext in ${HOSTEXT_IMAGES}; do
		export HOSTEXT_NAME=${hostext}
		PACKAGES=$(get_package_list "${hostext#"${MACHINE}-"}")
		[ -z "${PACKAGES}" ] && echo "No packages list found in extensions metadata" && exit 1
		"${script_dir}"/jenkins-hostapp-extension.sh ${PACKAGES}
	done
	# Remove packages folder from deploy directory
	rm -rf "${WORKSPACE}/deploy-jenkins/${PACKAGE_TYPE}"
fi

echo "[INFO] Building ${MACHINE} with shared dir ${YOCTO_DIR} and hostapp extension images ${HOSTEXT_IMAGES}"

# Build target images
"${script_dir}"/jenkins_build.sh -m "${MACHINE}" --preserve-build --shared-dir "${YOCTO_DIR}" --build-flavor "${buildFlavor}" --additional-variable HOSTEXT_IMAGES="${HOSTEXT_IMAGES}" --additional-variable BALENA_TOKEN="${BALENA_TOKEN}" --additional-variable BALENA_API_ENV="${API_ENV}"
