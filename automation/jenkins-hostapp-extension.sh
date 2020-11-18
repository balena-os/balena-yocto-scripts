#!/bin/bash 

set -e

[ $# -lt 2 ] && echo "Hostapp extension packages need to be defined" && exit 1
[ -z "${BALENAOS_STAGING_TOKEN}" ] && echo "Balena staging token is required" && exit 1
[ -z "${BALENAOS_PRODUCTION_TOKEN}" ] && echo "Balena production token is required" && exit 1
[ -z "${HOSTEXT_NAME}" ] && echo "Hostapp extension name is required" && exit 1
[ -z "${deployTo}" ] && echo "Deployment environment target is required" && exit 1
[ -z "${VERSION_HOSTOS}" ] && echo "Balena OS version is required" && exit 1
[ -z "${MACHINE}" ] && echo "Device type is required" && exit 1
[ -z "${PACKAGE_TYPE}" ] && echo "Package type is required" && exit 1

NAMESPACE=${NAMESPACE:-resin}

PACKAGES=""
for pkg in $@; do
	if [ -z "${PACKAGES}" ]; then
		PACKAGES="${pkg}"
	else
		PACKAGES="${PACKAGES} ${pkg}"
	fi
done

finish() {
	result=$?
	exit ${result}
}
trap finish EXIT ERR

script_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source "${script_dir}/balena-lib.sh"

deploy_to_balena() {
	local _exported_image_path=$1
	local DEVELOPMENT_IMAGE=no
	local _slug
	if [ "${buildFlavor}" = "dev" ]; then
		DEVELOPMENT_IMAGE=yes
	fi
	if ! docker_pull_helper_image "Dockerfile_balena-push-env"; then
		exit 1
	fi
	_slug=$(jq -r '.slug' "${script_dir}/../../${MACHINE}.json")
	docker run --rm -t \
		-e BALENAOS_STAGING_TOKEN="${BALENAOS_STAGING_TOKEN}" \
		-e BALENAOS_PRODUCTION_TOKEN="${BALENAOS_PRODUCTION_TOKEN}" \
		-e HOSTEXT_NAME="${HOSTEXT_NAME}" \
		-e deployTo="${deployTo}" \
		-e MACHINE="${_slug}" \
		-e balenaCloudEmail="${balenaCloudEmail}" \
		-e balenaCloudPassword="${balenaCloudPassword}" \
		${NAMESPACE}/balena-push-env /balena-create-public-app.sh
	docker run --rm -t \
		-e BASE_DIR=/host \
		-e BALENAOS_STAGING_TOKEN="${BALENAOS_STAGING_TOKEN}" \
		-e BALENAOS_PRODUCTION_TOKEN="${BALENAOS_PRODUCTION_TOKEN}" \
		-e APPNAME="${HOSTEXT_NAME}" \
		-e DEVELOPMENT_IMAGE="${DEVELOPMENT_IMAGE}" \
		-e DEPLOY_TO="${deployTo}" \
		-e VERSION_HOSTOS="${VERSION_HOSTOS}" \
		-e ESR="${ESR}" \
		-e META_BALENA_VERSION="${META_BALENA_VERSION}" \
		-v "${_exported_image_path}":/host/appimage.docker \
		--privileged \
		${NAMESPACE}/balena-push-env /balena-push-os-version.sh
}

WORKSPACE=${WORKSPACE:-"${PWD}"}

NAMESPACE=${NAMESPACE:-resin}

# Run build
if ! docker_pull_helper_image "Dockerfile_package-based-hostext.template"; then
	exit 1
fi
docker run --rm -t \
	-v "${WORKSPACE}":/yocto/resin-board \
	-e WORKSPACE=/yocto/resin-board \
	-e HOSTEXT_NAME="${HOSTEXT_NAME}" \
	-e PACKAGE_TYPE="${PACKAGE_TYPE}" \
	-e MACHINE="${MACHINE}" \
	-e VERSION_HOSTOS="${VERSION_HOSTOS}" \
	-e PACKAGES="${PACKAGES}" \
	-e NAMESPACE="${NAMESPACE}" \
	--privileged \
	${NAMESPACE}/${MACHINE}-package-based-hostext /balena-hostapp-extension.sh

if [ "${deployHostappExtension}" = "yes" ]; then
	deploy_to_balena "${WORKSPACE}/deploy-jenkins/${HOSTEXT_NAME}-${VERSION_HOSTOS}.docker"
fi

export HOSTEXT_SIZE=$(du -b "${WORKSPACE}/deploy-jenkins/${HOSTEXT_NAME}-${VERSION_HOSTOS}.docker" | awk '{print $1}')
exit 0
