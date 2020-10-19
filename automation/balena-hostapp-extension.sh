#!/bin/bash

set -e

[ -z "${MACHINE}" ] && echo "Machine needs to be defined" && exit 1
[ -z "${WORKSPACE}" ] && echo "Workspace needs to be defined" && exit 1
[ -z "${HOSTEXT_NAME}" ] && echo "Hostapp extension  name needs to be defined" && exit 1
[ -z "${PACKAGE_TYPE}" ] && echo "Package type needs to be defined" && exit 1
[ -z "${VERSION_HOSTOS}" ] && echo "Balena OS version needs to be defined" && exit 1
[ -z "${PACKAGES}" ] && echo "list of packages to install without dependencies" && exit 1

source /manage-docker.sh

trap 'cleanup fail' SIGINT SIGTERM

finish() {
	result=$?
	cleanup
	# Dockerd leaves a mount here
	if ! umount "${DOCKER_ROOT}"; then
		umount -l "${DOCKER_ROOT}" || true
	fi
	rm -rf "${TMPDIR}"
	exit ${result}
}
trap finish EXIT ERR

# Start docker
# Data root needs to be on a non-aufs directory to use balena build
TMPDIR=$(mktemp -d --tmpdir=${WORKSPACE:?})
DOCKER_ROOT="${TMPDIR}/docker"
echo "[INFO] Starting docker in ${DOCKER_ROOT}."
dockerd --data-root ${DOCKER_ROOT} > /var/log/docker.log 2>&1 &
wait_docker

DEVICE_TYPE_JSON="$WORKSPACE/$MACHINE.json"
if [ -e "${DEVICE_TYPE_JSON}" ]; then
	ARCH=$(jq --raw-output '.arch' "$DEVICE_TYPE_JSON")
fi

[ -z "${ARCH}" ] && echo "Device architecture is required" && exit 1

cp /Dockerfile.template "${TMPDIR}"
pushd "${TMPDIR}"

# Clean local docker of hostapp extensions
docker rmi -f $(docker images --filter "label=io.balena.features.host-extension" --format "{{.ID}}" | tr '\n' ' ') 2> /dev/null || true

ARCH_LIST=""
# Copy local package feed to context if available from previous build step
# Convention: Hostext service in compose file is called hostext and contains feed/ipk unless http feeds are used
if [ -d "${WORKSPACE}/deploy-jenkins/${PACKAGE_TYPE}" ]; then
	mkdir -p "${TMPDIR}/feed"
	cp -r "${WORKSPACE}/deploy-jenkins/${PACKAGE_TYPE}" "${TMPDIR}/feed/"
	# Extract package architecture list from feed
	# Each architecture is one directory
	while IFS=$'\n' read -r dir; do
		if [ -z "${ARCH_LIST}" ]; then
			ARCH_LIST="${dir}"
		else
			ARCH_LIST="${ARCH_LIST} ${dir}"
		fi
	done< <(find "${WORKSPACE}/deploy-jenkins/${PACKAGE_TYPE}" -mindepth 1 -maxdepth 1 -type d | xargs -I{} basename {})
fi

if balena build --logs --nocache --deviceType "${MACHINE}" --arch "${ARCH}" --buildArg PACKAGES="${PACKAGES}" --buildArg ARCH_LIST="${ARCH_LIST}" --buildArg NAMESPACE=${NAMESPACE:-resin}; then
	image_id=$(docker images --filter "label=io.balena.features.host-extension" --format "{{.ID}}")
	mkdir -p "${WORKSPACE}/deploy-jenkins"
	docker save "${image_id}" > "${WORKSPACE}/deploy-jenkins/${HOSTEXT_NAME}-${VERSION_HOSTOS}.docker"
else
	echo "[ERROR] Fail to build"
	exit 1
fi
popd

exit 0
