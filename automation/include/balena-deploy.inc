#!/bin/bash
set -e

VERBOSE=${VERBOSE:-0}
[ "${VERBOSE}" = "verbose" ] && set -x

include_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
device_dir=$( if cat /proc/self/cgroup | grep -q docker; then if [ -d "/work" ]; then cd "/work" && pwd; fi; else cd "${include_dir}/../../.." && pwd; fi )

source "${include_dir}/balena-api.inc"
source "${include_dir}/balena-lib.inc"
source "${include_dir}/balena-docker.inc"

# Deploys to passed container image to BalenaCloud
# Input arguments:
#  $1: Device type (defaults to MACHINE environmental variable)
#  $2: Balena environment
#  $3: Balena API token
#  $4: ESR release flag (default to "ESR" environment variable)
#  $5: Build variant (defaults to buildFlavor environment variable)
#  $6: BalenaOS account (defaults to balena_os)
#  $7: App name to deploy to (defaults to specified device type)
#
balena_deploy_hostapp() {
	local _device_type="${1:-"${MACHINE}"}"
	local _api_env="${2:-$(balena_lib_environment)}"
	local _token="${3:-$(balena_lib_token "${_api_env}")}"
	local _esr="${4}"
	local _variant="${5}"
	local _balenaos_account="${6}"
	local _app="${7}"
	local _balenaCloudEmail="${8:-"${balenaCloudEmail}"}"
	local _balenaCloudPassword="${9:-"${balenaCloudPassword}"}"
	local _version
	local _image_path
	[ -z "${_device_type}" ] && echo "[balena_deploy_hostapp] A device type is required" && return 1
	_image_path="$(readlink --canonicalize "${device_dir}/build/tmp/deploy/images/${_device_type}/balena-image-${_device_type}.docker")"
	if ! balena_lib_docker_pull_helper_image "Dockerfile_balena-push-env" balena_yocto_scripts_revision; then
		return 1
	fi

	[ -z "${_token}" ] && echo "A Balena token is required" && return 1
	[ -z "${_api_env}" ] && echo "A Balena environment is required" && return 1

	_version=${VERSION_HOSTOS:-$(balena_lib_get_os_version)}
	_app=${_app:-"${_device_type}"}
	_esr=${_esr:-"${ESR}"}
	_variant=${_variant:-"${buildFlavor}"}
	_meta_balena_version=${META_BALENA_VERSION:-$(balena_lib_get_meta_balena_version)}
	NAMESPACE=${NAMESPACE:-resin}
	_balenaos_account="${_balenaos_account:-"balena_os"}"

	# shellcheck disable=SC2154
	docker run --rm -t \
		-e BALENAOS_TOKEN="${_token}" \
		-e API_ENV="${_api_env}" \
		-e APPNAME="${_app}" \
		-e BALENAOS_ACCOUNT="${_balenaos_account}" \
		-e VARIANT="${_variant}" \
		-e RELEASE_VERSION="${_version}" \
		-e ESR="${_esr}" \
		-e MACHINE="${_device_type}" \
		-e VERBOSE="${VERBOSE}" \
		-e balenaCloudEmail="${_balenaCloudEmail}" \
		-e BOOTABLE="1" \
		-e balenaCloudPassword="${_balenaCloudPassword}" \
		-e META_BALENA_VERSION="${_meta_balena_version}" \
		-v "${_image_path}":/host/appimage.docker \
		-v "${device_dir}":/work \
		--privileged \
		"${NAMESPACE}"/balena-push-env:"${balena_yocto_scripts_revision}" /balena-deploy-block.sh

	balena_lib_docker_remove_helper_images "balena-push-env"
}

# Deploy Jenkins build artifacts
#
# Inputs:
#
# $1: Device type name
# $2: Directory to deploy to
# $3: Remove compressed files (defaults to true)
# $4: Preserve the build directory (default to no)
#
balena_deploy_artifacts () {
	local _device_type="${1}"
	local _deploy_dir="${2}"
	local _remove_compressed_file="${3:-"true"}"
	local _preserve_build="${4}"
	local _device_type_json="${device_dir}/${_device_type}.json"
	local _deploy_artifact
	local _image
	local _deploy_flasher_artifact
	local _compressed
	local _archive
	local _device_state
	local _yocto_build_deploy
	local _slug


	[ ! -f "${_device_type_json}" ] && echo "[balena_deploy_artifacts] Device type JSON not found" && return

	_deploy_artifact=$(jq --raw-output '.yocto.deployArtifact' "${_device_type_json}")
	_image=$(jq --raw-output '.yocto.image' "${_device_type_json}")
	_deploy_flasher_artifact=$(jq --raw-output '.yocto.deployFlasherArtifact // empty' "${_device_type_json}")
	_compressed=$(jq --raw-output '.yocto.compressed' "${_device_type_json}")
	_archive=$(jq --raw-output '.yocto.archive' "$_device_type_json")
	_device_state=$(jq --raw-output '.state' "${_device_type_json}")
	_yocto_build_deploy="${device_dir}/build/tmp/deploy/images/${_device_type}"
	_slug=$(jq --raw-output '.slug' "${_device_type_json}")

	[ -z "${_preserve_build}" ] && rm -rf "${_deploy_dir}"
	mkdir -p "${_deploy_dir}/image"

	cp -v "$_device_type_json" "$_deploy_dir/device-type.json"
	if [ "${_device_state}" = "DISCONTINUED" ]; then
	       echo "${_device_type} is discontinued so only device-type.json will be deployed as build artifact."
	       return
	fi

	cp -v "$_yocto_build_deploy/VERSION" "$_deploy_dir"
	cp -v "$_yocto_build_deploy/VERSION_HOSTOS" "$_deploy_dir"
	cp -v "$(readlink --canonicalize "$_yocto_build_deploy/$_image-${_device_type}.manifest")" "$_deploy_dir/$_image-$_device_type.manifest"
	cp -v "$(readlink --canonicalize "$_yocto_build_deploy/balena-image-$_device_type.docker")" "$_deploy_dir/balena-image.docker"

	test "${_slug}" = "edge" && return

	if [ "$_deploy_artifact" = "docker-image" ]; then
		echo "[WARN] No artifacts to deploy. The images will be pushed to docker registry."
		return
	fi

	cp -v "$_yocto_build_deploy/kernel_modules_headers.tar.gz" "$_deploy_dir" || true
	cp -v "$_yocto_build_deploy/kernel_source.tar.gz" "$_deploy_dir" || true
	cp -v "$_device_type.svg" "$_deploy_dir/logo.svg"
	if [ "${_compressed}" != 'true' ]; then
		# uncompressed, just copy and we're done
		cp -v "$(readlink --canonicalize "$_yocto_build_deploy/$_deploy_artifact")" "$_deploy_dir/image/balena.img"
		if [ -n "$_deploy_flasher_artifact" ]; then
			cp -v "$(readlink --canonicalize "$_yocto_build_deploy/$_deploy_flasher_artifact")" "$_deploy_dir/image/resin-flasher.img"
		fi
		return
	fi

	if [ "${_archive}" = 'true' ]; then
		cp -rv "$_yocto_build_deploy"/"$_deploy_artifact"/* "$_deploy_dir"/image/
		(cd "$_deploy_dir/image/" && zip -r "../$_deploy_artifact.zip" .)
		if [ -n "$_deploy_flasher_artifact" ]; then
		    cp -rv "$_yocto_build_deploy"/"$_deploy_flasher_artifact"/* "$_deploy_dir"/image/
		    (cd "$_deploy_dir/image/" && zip -r "../$_deploy_flasher_artifact.zip" .)
		fi
		if [ "$_remove_compressed_file" = "true" ]; then
			rm -rf "$_deploy_dir/image"
		fi
	else
		cp -v "$(readlink --canonicalize "$_yocto_build_deploy/$_deploy_artifact")" "$_deploy_dir/image/balena.img"
		(cd "$_deploy_dir/image" && zip balena.img.zip balena.img)
		if [ -n "$_deploy_flasher_artifact" ]; then
			cp -v "$(readlink --canonicalize "$_yocto_build_deploy/$_deploy_flasher_artifact")" "$_deploy_dir/image/resin-flasher.img"
			(cd "$_deploy_dir/image" && zip resin-flasher.img.zip resin-flasher.img)
		fi
		if [ "$_remove_compressed_file" = "true" ]; then
			rm -rf "$_deploy_dir/image/balena.img"
			rm -rf "$_deploy_dir/image/resin-flasher.img"
		fi
	fi

	if [ -d "${device_dir}/layers/meta-balena/tests" ]
	then
		# package all leviathan/testbot tests from meta-balena to the deploy dir
		# make sure they are compressed so a flattened unzip of artifacts does not fail
		(cd "${device_dir}/layers/meta-balena/tests" || return
			[ -f suites/config.js ] && sed "s/deviceType: .*/deviceType: '${MACHINE}',/g" -i suites/config.js
			tar -czvf "$_deploy_dir/tests.tar.gz" .
		)
	fi
}

# Deploy docker images to dockerhub registry
#
# Inputs:
#
# $1: Device type name
# $2: Build variant (prod | dev) (defaults to buildFlavor environmental variable)
# $3: Account to deploy to (production | staging) (defaults to deployTo enviromental variable)
# $4: Account namespace to use (defaults to resin)
#
balena_deploy_to_dockerhub () {
	local _device_type="${1:-${MACHINE}}"
	local _variant="${2:-"${buildFlavor}"}"
	local _deploy_to="${3:-"${deployTo}"}"
	local _namespace="${4:-resin}"
	local _version
	local _private
	local _docker_repo
	local _exported_image_path
	local _slug
	local _tag
	local _hostapp_image

	_version=$(balena_lib_get_os_version)
	[ -z "${_device_type}" ] && echo "[balena_deploy_to_dockerhub] Device type is required" && return 1
	[ -z "${_variant}" ] && echo "[balena_deploy_to_dockerhub] OS variant is required" && return 1

	_private=$(balena_api_is_dt_private "${_device_type}")

	_exported_image_path=$(readlink --canonicalize "${device_dir}/build/tmp/deploy/images/${_device_type}/balena-image-${_device_type}.docker")

	_slug=$(balena_lib_get_slug "${_device_type}")
	[ -z "${_namespace}" ] && _namespace="${NAMESPACE:="resin"}"

	local _docker_repo="${_namespace}/resinos"
	if [ "${_deploy_to}" = "staging" ]; then
		_docker_repo="${_namespace}/resinos-staging"
	fi
	if [ "${_variant}" = "dev" ]; then
		_variant=".dev"
	else
		_variant=""
	fi
	# Make sure the tags are valid
	# https://github.com/docker/docker/blob/master/vendor/github.com/docker/distribution/reference/regexp.go#L37
	_tag="$(echo "${_version}${_variant}-${_slug}" | sed 's/[^a-z0-9A-Z_.-]/_/g')"

	balena_lib_dockerhub_login

	echo "[INFO] Pushing image to dockerhub $_docker_repo:$_tag..."

	if [ ! -f "${_exported_image_path}" ]; then
		echo "[ERROR] The build didn't produce a valid image."
		return 1
	fi

	_hostapp_image=$(docker load --quiet -i "$_exported_image_path" | cut -d: -f1 --complement | tr -d ' ')
	docker tag "$_hostapp_image" "$_docker_repo:$_tag"

	# We only push to dockerhub if it is a public image.
	if [ "$_private" = "false" ]; then
		docker push "$_docker_repo":"$_tag"
	fi

	docker rmi -f "$_hostapp_image"
}

# Deploy artifacts to S3
#
# Inputs:
#
# $1: Device type name
# $2: Build variant (prod | dev )
# $3: ESR flag
# $4: S3 environmennt to deploy to (production | staging ) (defaults to production)
# $5: S3 account namespace to use (defaults to resin)
#
balena_deploy_to_s3() {
	local _device_type="${1}"
	local _variant="${2}"
	local _esr=${3}
	local _deploy_to="${4:-"production"}"
	local _namespace="${5}"
	local _slug
	local _artifact
	local _state
	local _s3_bucket
	local _s3_bucket_prefix
	local _s3_bucket_suffix
	local _is_private
	local _s3_version_hostos

	_slug=$(balena_lib_get_slug "${_device_type}")
	_artifact=$(balena_lib_get_deploy_artifact "${_device_type}")
	_state=$(balena_lib_get_dt_state "${_device_type}")

	[ -z "${_device_type}" ] && echo "[balena_deploy_to_s3] Device type is required" && return 1
	[ -z "${_variant}" ] && echo "[balena_deploy_to_s3] Variant is required" && return 1
	if [ "${_variant}" != "prod" ] && [ "${_variant}" != "dev" ]; then
		echo "[balena_deploy_to_s3] Invalid variant ${_variant}"
		return 1
	fi
	_s3_version_hostos="$(balena_lib_get_os_version).${_variant}"

	[ -z "${_namespace}" ] && _namespace=${NAMESPACE:-"resin"}
	[ -z "${_esr}" ] && _esr="${_esr:-"${ESR:-false}"}"
	local _s3_deploy_dir="${device_dir}/deploy-s3"
	local _s3_deploy_images_dir="$_s3_deploy_dir/$_slug/$_s3_version_hostos"

	balena_deploy_artifacts "${MACHINE}" "$_s3_deploy_images_dir" "false"

	_s3_bucket_suffix="images"
	if [ "${_esr}" =  "true" ]; then
		_s3_bucket_suffix="esr-images"
	fi
	_s3_bucket_prefix="resin-production-img-cloudformation"
	_s3_bucket="${_s3_bucket_prefix}/${_s3_bucket_suffix}"

	local _s3_access_key _s3_secret_key
	if [ "${_deploy_to}" = "production" ]; then
		[ -z "${PRODUCTION_S3_ACCESS_KEY}" ] || [ -z "${PRODUCTION_S3_SECRET_KEY}" ] && echo "[balena_deploy_to_s3] ${_deploy_to} keys are required" && return 1
		_s3_access_key=${PRODUCTION_S3_ACCESS_KEY}
		_s3_secret_key=${PRODUCTION_S3_SECRET_KEY}
	elif [ "$_deploy_to" = "staging" ]; then
		[ -z "${STAGING_S3_ACCESS_KEY}" ] || [ -z "${STAGING_S3_SECRET_KEY}" ] && echo "[balena_deploy_to_s3] ${_deploy_to} keys are required" && return 1
		_s3_access_key=${STAGING_S3_ACCESS_KEY}
		_s3_secret_key=${STAGING_S3_SECRET_KEY}

		_s3_bucket_prefix="resin-staging-img"
		_s3_bucket="${_s3_bucket_prefix}/${_s3_bucket_suffix}"
	else
		echo "[ERROR] Refusing to deploy to anything other than production or staging."
		return 1
	fi

	local _s3_policy="private"
	_is_private=$(balena_api_is_dt_private "${_device_type}")
	if [ "${_is_private}" = "false" ]; then
		_s3_policy="public-read"
	fi

	local _s3_cmd="s4cmd --access-key=${_s3_access_key} --secret-key=${_s3_secret_key}"
	local _s3_sync_opts="--recursive --API-ACL=${_s3_policy}"
	docker pull ${_namespace}/resin-img:master
	docker run --rm -t \
		-e BASE_DIR=/host/images \
		-e S3_CMD="$_s3_cmd" \
		-e S3_SYNC_OPTS="$_s3_sync_opts" \
		-e S3_BUCKET="$_s3_bucket" \
		-e SLUG="$_slug" \
		-e DEPLOY_ARTIFACT="${_artifact}" \
		-e BUILD_VERSION="$_s3_version_hostos" \
		-e DEVELOPMENT_IMAGE="${_variant}" \
		-e VERBOSE="${VERBOSE}" \
		-e DEPLOYER_UID="$(id -u)" \
		-e DEPLOYER_GID="$(id -g)" \
		-e DEVICE_STATE="${_state}" \
		-v "$_s3_deploy_dir":/host/images "${_namespace}"/resin-img:master /bin/sh -e -c ' \
			VERBOSE=${VERBOSE:-0}
			[ "${VERBOSE}" = "verbose" ] && set -x
			apt-get -y update
			apt-get install -y s4cmd
			echo "Creating and setting deployer user $DEPLOYER_UID:$DEPLOYER_GID."
			groupadd -g $DEPLOYER_GID deployer
			useradd -m -u $DEPLOYER_UID -g $DEPLOYER_GID deployer
			su deployer<<EOSU
set -e
VERBOSE=${VERBOSE:-0}
[ "${VERBOSE}" = "verbose" ] && set -x
echo "${BUILD_VERSION}" > "/host/images/${SLUG}/latest"
if [ "$DEPLOY_ARTIFACT" = "docker-image" ] || [ "$DEVICE_STATE" = "DISCONTINUED" ]; then
	echo "WARNING: No raw image prepare step for docker images only artifacts or discontinued device types."
else
	/usr/src/app/node_modules/.bin/ts-node /usr/src/app/scripts/prepare.ts
fi
if [ -z "$($S3_CMD ls s3://${S3_BUCKET}/${SLUG}/${BUILD_VERSION}/)" ] || [ -n "$($S3_CMD ls s3://${S3_BUCKET}/${SLUG}/${BUILD_VERSION}/IGNORE)" ]; then
	touch /host/images/${SLUG}/${BUILD_VERSION}/IGNORE
	$S3_CMD del -rf s3://${S3_BUCKET}/${SLUG}/${BUILD_VERSION}
	$S3_CMD put /host/images/${SLUG}/${BUILD_VERSION}/IGNORE s3://${S3_BUCKET}/${SLUG}/${BUILD_VERSION}/
	$S3_CMD $S3_SYNC_OPTS dsync /host/images/${SLUG}/${BUILD_VERSION}/ s3://${S3_BUCKET}/${SLUG}/${BUILD_VERSION}/
	if [ "${DEVELOPMENT_IMAGE}" = "prod" ]; then
		$S3_CMD put /host/images/${SLUG}/latest s3://${S3_BUCKET}/${SLUG}/ --API-ACL=public-read -f
	fi
	$S3_CMD put /host/images/${SLUG}/${BUILD_VERSION}/logo.svg s3://${S3_BUCKET}/${SLUG}/${BUILD_VERSION}/ --API-ACL=public-read -f --API-ContentType=image/svg+xml
	$S3_CMD del s3://${S3_BUCKET}/${SLUG}/${BUILD_VERSION}/IGNORE
else
	echo "WARNING: Deployment already done for ${SLUG} at version ${BUILD_VERSION}"
fi
EOSU
		'
}

# Builds and deploys the specified block to BalenaCloud
# Input arguments;
#  $1: App name to deploy into
#  $2: Path to the image to deploy
#  $3: Device type for the app
#  $4: BalenaCloud email address (defaults to the balenaCloudEmail enviromental variable)
#  $5: BalenaCloud password (defaults to the balenaCloudPassword enviromental variable)
#
balena_deploy_block() {
	local _appName="$1"
	local _image_path="${2}"
	local _device_type="${3:-${MACHINE}}"
	local _bootable=${4:-"0"}
	local _balenaos_account="${5:-"balena_os"}"
	local _balenaCloudEmail="${6:-"${balenaCloudEmail}"}"
	local _balenaCloudPassword="${7:-"${balenaCloudPassword}"}"

	[ -z "${_appName}" ] && echo "App name is required" && return
	[ -z "${_image_path}" ] && echo "Image path is required" && return
	[ -z "${_device_type}" ] && echo "Device type is required" && return

	NAMESPACE=${NAMESPACE:-resin}
	if ! balena_lib_docker_pull_helper_image "Dockerfile_balena-push-env" balena_yocto_scripts_revision; then
		return 1
	fi
	docker run --rm -t \
		-e APPNAME="${_appName}" \
		-e API_ENV="$(balena_lib_environment)" \
		-e BALENAOS_TOKEN="$(balena_lib_token "${API_ENV}")" \
		-e BALENAOS_ACCOUNT="${_balenaos_account}" \
		-e RELEASE_VERSION="$(balena_lib_get_os_version)" \
		-e MACHINE="${_device_type}" \
		-e VERBOSE="${VERBOSE}" \
		-e BOOTABLE="${_bootable}" \
		-e balenaCloudEmail="${_balenaCloudEmail}" \
		-e balenaCloudPassword="${_balenaCloudPassword}" \
		-v "${_image_path}":/host/appimage.docker \
		--privileged \
		"${NAMESPACE}"/balena-push-env:"${balena_yocto_scripts_revision}" /balena-deploy-block.sh

	balena_lib_docker_remove_helper_images "balena-push-env"
}

# Builds and deploys the specified block to BalenaCloud
# Input arguments;
#  $1: App name to deploy into
#  $2: Device type for the app
#  $3: Package list to build the block with
#  $4: Balena cloud account (defaults to balena_os)
#  $5: Balena API environment
#
balena_deploy_build_block() {
	local _appName="$1"
	local _device_type="${2:-${MACHINE}}"
	local _packages="${3:-${PACKAGES}}"
	local _balenaos_account="${4:-balena_os}"
	local _api_env="${5:-$(balena_lib_environment)}"

	[ -z "${_appName}" ] && echo "App name is required" && return
	[ -z "${_device_type}" ] && echo "Device type is required" && return
	[ -z "${_packages}" ] && echo "Package list is required" && return

	if ! balena_lib_docker_pull_helper_image "Dockerfile_yocto-block-build-env" balena_yocto_scripts_revision; then
		return 1
	fi
	docker run --rm -t \
		-e APPNAME="${_appName}" \
		-e API_ENV="${_api_env}" \
		-e BALENAOS_TOKEN="$(balena_lib_token "${API_ENV}")" \
		-e NAMESPACE="${NAMESPACE:-resin}" \
		-e BALENAOS_ACCOUNT="${_balenaos_account}" \
		-e RELEASE_VERSION="$(balena_lib_get_os_version)" \
		-e PACKAGES="${_packages}" \
		-e VERBOSE="${VERBOSE}" \
		-e MACHINE="${_device_type}" \
		-e TAG="${balena_yocto_scripts_revision}" \
		-e WORKSPACE=/work \
		-e balenaCloudEmail="${balenaCloudEmail}" \
		-e balenaCloudPassword="${balenaCloudPassword}" \
		-v "${WORKSPACE:-"${PWD}"}":/work \
		--privileged \
		"${NAMESPACE}"/yocto-block-build-env:"${balena_yocto_scripts_revision}" /balena-build-block.sh

	balena_lib_docker_remove_helper_images "yocto-block-build-env"
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

# Deploy a package feed locally
#
# Inputs:
#
# $1: Directory to deploy to
# $2: Package type (defaults to ipk)
#
# Output
#
# 0 on success or 1 on failure
#
balena_deploy_feed() {
	local _deploy_dir="${1}"
	local _package_type="${2}"

	[ -z "${_deploy_dir}" ] && >&2 echo "Deploy directory is required" && return 1

	_package_type="${_package_type:-"ipk"}"
	if [ -e "${device_dir}/build/tmp/deploy/${_package_type}" ]; then
		echo "[INFO]: Deploying package feed"
		mkdir -p "$_deploy_dir/${_package_type}"
		cp -r "${device_dir}/build/tmp/deploy/${_package_type}" "$_deploy_dir/"
	fi
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
	printf "    image: %s\n" "${_image}" >> "${_path}/docker-compose.yml"
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
# $5: HostOS blocks - default to none
#
# Outputs:
#    Path where the compose file is created
#
__create_compose_file() {
	local _device_type="$1"
	local _apiEnv="$2"
	local _version="$3"
	local _token="$4"
	local _blocks="$5"
	local _path
	local _block_image
	local _class
	local _store
	local _reboot_required
	local _block
	local _image_id
	local _bootable

	[ -z "${_device_type}" ] && return
	_version=${version:-$(balena_lib_get_os_version)}
	_apiEnv=${_apiEnv:-"balena-cloud.com"}
	[ -z "${_path}" ] && _path=$(mktemp -d)

	[ -z "${_blocks}" ] && >&2 echo "Blocks are required" && return 1
	for _block in ${_blocks}; do
		_block_image=$(balena_api_fetch_image_from_app "${_block}" "${_version}" "${_apiEnv}")
		_image_id=$(balena_docker_image_retrieve "${_block_image}")
		if [ -z "${_block_image}" ] || [ "${_block_image}" = "" ]; then
			>&2 echo "[${_block}] No such image for ${_version} in ${_apiEnv}"
			continue
		fi
		_class=$(balena_lib_get_label_from_image "${_image_id}" "${BALENA_HOSTOS_BLOCK_CLASS}")
		_store=$(balena_lib_get_label_from_image "${_image_id}" "${BALENA_HOSTOS_BLOCK_STORE}")
		_reboot_required=$(balena_lib_get_label_from_image "${_image_id}" "${BALENA_HOSTOS_BLOCK_REQUIRES_REBOOT}")
		_bootable=$(balena_api_is_bootable "${_block}" "${_apiEnv}" "${_token}")
		__add_compose_service "${_path}" "${_block}" "${_block_image}" "${_class}" "${_reboot_required}" "${_store}" "${_bootable}"
	done
	echo "${_path}"
}

# Deploys a multi-container hostOS
#
# Inputs:
# $1: Application name
# $2: HostOS blocks - required
# $3: Device type for the application
# $4: Balena API environment (default to balena-cloud.com)
# $5: Balena API token (defaults to ~/.balena/token)
# $6: Balena cloud account (defaults to balena_os)
# $7: Bootable 0 or 1 (default)
#
# Outputs:
#    None
#
balena_deploy_hostos() {
	local _appName="$1"
	local _blocks="$2"
	local _device_type="$3"
	local _apiEnv="$4"
	local _token="$5"
	local _account="$6"
	local _bootable="${7:-1}"
	local _path

	_apiEnv=${_apiEnv:-"$(balena_lib_environment)"}
	_account=${_account:-"balena_os"}
	_token=${_token:-"$(balena_lib_token "${_apiEnv}")"}
	_version=$(balena_lib_get_os_version)
	[ -z "${_version}" ] && >&2 echo "Invalid version" && return
	[ -z "${_device_type}" ] && >&2 echo "Required device type" && return
	_path=$(__create_compose_file "${_device_type}" "${_apiEnv}" "${_version}" "${_token}" "${_blocks}")
	if [ -n "${balenaCloudEmail}" ] && [ -n "${balenaCloudPassword}" ]; then
		balena_api_create_public_app "${_appName}" "${_apiEnv}" "${_device_type}" "${balenaCloudEmail}" "${balenaCloudPassword}" "${_bootable}"
	else
		>&2 echo "Balena credentials need to be available in the environment to create public apps"
	fi

	if balena_api_get_release "${_appName}" "${_version}" "${_apiEnv}"; then
		>&2 echo "[INFO] Release ${_version} already exists for ${_appName}"
		return
	fi
	balena_lib_login "${_apiEnv}" "${_token}"
	if [ ! -f "${_path}/docker-compose.yml" ]; then
		>&2 echo "No compose file in ${_path}"
		return
	fi
	_releaseID=$(BALENARC_BALENA_URL="${_apiEnv}" balena deploy "${_appName}" --build --source "${_path}" | sed -n 's/.*Release: //p')
	echo "${_releaseID} deployed to ${_appName}"
	balena_api_set_release_version "${_releaseID}" "${_apiEnv}" "${_token}" "${_version}"
}
