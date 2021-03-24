#!/bin/bash
set -e

script_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
device_dir=$(realpath "${script_dir}/../../")
BALENA_YOCTO_SCRIPTS_REVISION=$(cd "${script_dir}" && git rev-parse --short HEAD)

source "${script_dir}/balena-api.inc"
source "${script_dir}/balena-lib.inc"

# Deploys to passed container image to BalenaCloud
# Input arguments:
#  $1: Path to the local image to deploy
#  $2: Balena environment
#  $3: Balena API token
#  $4: BalenaOS account (defaults to balena_os)
#  $5: ESR release flag (default to "ESR" environment variable)
#  $6: Development flag (defaults to DEVELOPMENT_IMAGE environment variable)
#  $7: App name to deploy to (defaults to SLUG environment variable)
#
balena_deploy_hostapp() {
	local _image_path="${1}"
	local _api_env="${2}"
	local _token="${3}"
	local _balenaos_account="${4}"
	local _esr="${5}"
	local _variant="${6}"
	local _app="${7}"
	local _version
	if ! balena_lib_docker_pull_helper_image "Dockerfile_balena-push-env" balena_yocto_scripts_revision; then
		exit 1
	fi

	[ -z "${_image_path}" ] && echo "An image is required" && return
	[ -z "${_token}" ] && echo "A Balena token is required" && return
	[ -z "${_api_env}" ] && echo "A Balena environment is required" && return

	_version=${VERSION_HOSTOS:-$(balena_lib_get_os_version)}
	_app=${_app:="${MACHINE}"}
	_esr=${_esr:-"${ESR}"}
	_variant=${_variant:-"${buildFlavor}"}
	_meta_balena_version=${META_BALENA_VERSION:-$(balena_lib_get_meta_balena_version)}
	NAMESPACE=${NAMESPACE:-resin}
        _balenaos_account="${_balenaos_account:-"balena_os"}"

	# shellcheck disable=SC2154
	docker run --rm -t \
		-e BASE_DIR=/host \
		-e TOKEN="${_token}" \
		-e API_ENV="${_api_env}" \
		-e APPNAME="${_app}" \
		-e BALENAOS_ACCOUNT="${_balenaos_account}" \
		-e VARIANT="${_variant}" \
		-e VERSION_HOSTOS="${_version}" \
		-e ESR="${_esr}" \
		-e META_BALENA_VERSION="${_meta_balena_version}" \
		-v "${_image_path}":/host/appimage.docker \
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
	_archive=$(jq --raw-output '.yocto.archive' "${_device_type_json}")
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
		(cd "${device_dir}/layers/meta-balena/tests" && tar -czvf "$_deploy_dir/tests.tar.gz" .)
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
	[ -z "${_device_type}" ] && echo "[balena_deploy_to_dockerhub] Device type is required" && return 1
	[ -z "${_variant}" ] && echo "[balena_deploy_to_dockerhub] OS variant is required" && return 1
	_version=$(balena_lib_get_os_version)

	local _private
	_private=$(balena_api_is_dt_private "${_device_type}")
	local _docker_repo

	local _exported_image_path
	_exported_image_path=$(readlink --canonicalize "${device_dir}/build/tmp/deploy/images/${_device_type}/balena-image-${_device_type}.docker")

	local _slug
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
	local _tag
	_tag="$(echo "${_version}${_variant}-${_slug}" | sed 's/[^a-z0-9A-Z_.-]/_/g')"

	balena_lib_dockerhub_login

	echo "[INFO] Pushing image to dockerhub $_docker_repo:$_tag..."

	if [ ! -f "$_exported_image_path" ]; then
		echo "[ERROR] The build didn't produce a valid image."
		exit 1
	fi

	local _hostapp_image
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

	[ -z "${_namespace}" ] && _namespace=${NAMESPACE:-"resin"}
	[ -z "${_esr}" ] && _esr="${_esr:-"${ESR:-false}"}"
	_s3_version_hostos="$(balena_lib_get_os_version).${_variant}"
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
		exit 1
	fi

	local _s3_policy="private"
	local _is_private
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
		-e DEPLOYER_UID="$(id -u)" \
		-e DEPLOYER_GID="$(id -g)" \
		-e DEVICE_STATE="${_state}" \
		-v "$_s3_deploy_dir":/host/images "${_namespace}"/resin-img:master /bin/sh -x -e -c ' \
			apt-get -y update
			apt-get install -y s4cmd
			echo "Creating and setting deployer user $DEPLOYER_UID:$DEPLOYER_GID."
			groupadd -g $DEPLOYER_GID deployer
			useradd -m -u $DEPLOYER_UID -g $DEPLOYER_GID deployer
			su deployer<<EOSU
set -ex
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
