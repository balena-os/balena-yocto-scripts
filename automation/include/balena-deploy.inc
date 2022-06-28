#!/bin/bash
set -e

VERBOSE=${VERBOSE:-0}
[ "${VERBOSE}" = "verbose" ] && set -x

include_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
device_dir=$( if cat /proc/self/cgroup | grep -q docker; then if [ -d "/work" ]; then cd "/work" && pwd; fi; else cd "${include_dir}/../../.." && pwd; fi )

source "${include_dir}/balena-api.inc"
source "${include_dir}/balena-lib.inc"
source "${include_dir}/balena-docker.inc"

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
	local _deploy_raw_artifact
	local _compressed
	local _archive
	local _device_state
	local _yocto_build_deploy
	local _slug


	[ ! -f "${_device_type_json}" ] && echo "[balena_deploy_artifacts] Device type JSON not found" && return

	_deploy_artifact=$(jq --raw-output '.yocto.deployArtifact' "${_device_type_json}")
	_image=$(jq --raw-output '.yocto.image' "${_device_type_json}")
	_deploy_flasher_artifact=$(jq --raw-output '.yocto.deployFlasherArtifact // empty' "${_device_type_json}")
	_deploy_raw_artifact=$(jq --raw-output '.yocto.deployRawArtifact // empty' "${_device_type_json}")
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
	if [ "${_compressed}" != 'true' ]; then
		# uncompressed, just copy and we're done
		cp -v "$(readlink --canonicalize "$_yocto_build_deploy/$_deploy_artifact")" "$_deploy_dir/image/balena.img"
		if [ -n "$_deploy_flasher_artifact" ]; then
			cp -v "$(readlink --canonicalize "$_yocto_build_deploy/$_deploy_flasher_artifact")" \
				"$_deploy_dir/image/balena-flasher.img"
		fi

		if [ -n "${_deploy_raw_artifact}" ]; then
			cp -v "$(readlink --canonicalize "$_yocto_build_deploy/$_deploy_raw_artifact")" \
				"$_deploy_dir/image/balena-raw.img"
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
		if [ -n "$_deploy_raw_artifact" ]; then
			cp -rv "$_yocto_build_deploy"/"$_deploy_raw_artifact"/* "$_deploy_dir"/image/
			(cd "$_deploy_dir/image/" && zip -r "../$_deploy_raw_artifact.zip" .)
		fi
		if [ "$_remove_compressed_file" = "true" ]; then
			rm -rf "$_deploy_dir/image"
		fi
	else
		cp -v "$(readlink --canonicalize "$_yocto_build_deploy/$_deploy_artifact")" "$_deploy_dir/image/balena.img"
		(cd "$_deploy_dir/image" && zip balena.img.zip balena.img)
		if [ -n "$_deploy_flasher_artifact" ]; then
			cp -v "$(readlink --canonicalize "$_yocto_build_deploy/$_deploy_flasher_artifact")" \
				"$_deploy_dir/image/balena-flasher.img"
			(cd "$_deploy_dir/image" && zip balena-flasher.img.zip balena-flasher.img)
		fi
		if [ -n "$_deploy_raw_artifact" ]; then
			cp -v "$(readlink --canonicalize "$_yocto_build_deploy/$_deploy_raw_artifact")" \
				"$_deploy_dir/image/balena-raw.img"
			(cd "$_deploy_dir/image" && zip balena-raw.img.zip balena-raw.img)
		fi
		if [ "$_remove_compressed_file" = "true" ]; then
			rm -rf "$_deploy_dir/image/balena.img"
			rm -rf "$_deploy_dir/image/balena-flasher.img"
			rm -rf "$_deploy_dir/image/balena-raw.img"
		fi
	fi

	if [ -d "${device_dir}/layers/meta-balena/tests" ]
	then
		# package all leviathan/testbot tests from meta-balena to the deploy dir
		# make sure they are compressed so a flattened unzip of artifacts does not fail
		(cd "${device_dir}/layers/meta-balena/tests" || return
			tar -czvf "$_deploy_dir/tests.tar.gz" .
		)
	fi
}

# Deploy docker images to dockerhub registry
#
# Inputs:
#
# $1: Device type name
# $2: Account to deploy to (production | staging) (defaults to deployTo enviromental variable)
# $3: Account namespace to use (defaults to resin)
#
balena_deploy_to_dockerhub () {
	local _device_type="${1:-${MACHINE}}"
	local _deploy_to="${2:-"${deployTo}"}"
	local _namespace="${3:-resin}"
	local _version
	local _private
	local _docker_repo
	local _exported_image_path
	local _slug
	local _tag
	local _hostapp_image
	local _discontinued

	[ -z "${_device_type}" ] && echo "[balena_deploy_to_dockerhub] Device type is required" && return 1
	_discontinued=$(balena_lib_get_dt_state "${_device_type}")
	if [ "${_discontinued}" = "DISCONTINUED" ]; then
		echo "[INFO]: balena_deploy_to_dockerhub: Not deploying discontinued device type."
		return
	fi

	_version=$(balena_lib_get_os_version)

	_private=$(balena_api_is_dt_private "${_device_type}")

	_exported_image_path=$(readlink --canonicalize "${device_dir}/build/tmp/deploy/images/${_device_type}/balena-image-${_device_type}.docker")

	_slug=$(balena_lib_get_slug "${_device_type}")
	[ -z "${_namespace}" ] && _namespace="${NAMESPACE:="resin"}"

	local _docker_repo="${_namespace}/resinos"
	if [ "${_deploy_to}" = "staging" ]; then
		_docker_repo="${_namespace}/resinos-staging"
	fi
	# Make sure the tags are valid
	# https://github.com/docker/docker/blob/master/vendor/github.com/docker/distribution/reference/regexp.go#L37
	_tag="$(echo "${_version}-${_slug}" | sed 's/[^a-z0-9A-Z_.-]/_/g')"

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
# $2: ESR flag
# $3: S3 environmennt to deploy to (production | staging ) (defaults to production)
# $4: S3 account namespace to use (defaults to resin)
#
balena_deploy_to_s3() {
	local _device_type="${1}"
	local _esr=${2}
	local _deploy_to="${3:-"production"}"
	local _namespace="${4}"
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
	if [ "${_state}" != "DISCONTINUED" ]; then
		_s3_version_hostos="$(balena_lib_get_os_version)"
	else
		_s3_version_hostos="$(balena_lib_get_meta_balena_version)"
	fi

	[ -z "${_namespace}" ] && _namespace=${NAMESPACE:-"balena"}
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
	docker pull "${_namespace}/balena-img:4.1.2"
	docker run --rm -t \
		-e BASE_DIR=/host/images \
		-e S3_CMD="$_s3_cmd" \
		-e S3_SYNC_OPTS="$_s3_sync_opts" \
		-e S3_BUCKET="$_s3_bucket" \
		-e SLUG="$_slug" \
		-e DEPLOY_ARTIFACT="${_artifact}" \
		-e BUILD_VERSION="$_s3_version_hostos" \
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
	$S3_CMD put /host/images/${SLUG}/latest s3://${S3_BUCKET}/${SLUG}/ --API-ACL=public-read -f
	$S3_CMD del s3://${S3_BUCKET}/${SLUG}/${BUILD_VERSION}/IGNORE
else
	echo "WARNING: Deployment already done for ${SLUG} at version ${BUILD_VERSION}"
fi
EOSU
		'
}

# Builds and deploys to BalenaCloud
# Input arguments;
#  $1: App name to deploy into
#  $2: Device type for the app
#  $3: Deploy to balenaCloud fleet as draft (default) or final release
#  $4: Block names to deploy (defaults to hostapp)
#  $5: Path to the working directory (defaults to device repository root)
#  $6: Bootable flag - defaults to 1
#  $7: BalenaCloud admin account (defaults to balena_os)
#  $8: BalenaCloud email address (defaults to the balenaCloudEmail enviromental variable)
#  $9: BalenaCloud password (defaults to the balenaCloudPassword enviromental variable)
#  $10: ESR release flag (default to "ESR" environment variable)
#
balena_deploy() {
	local _appName="$1"
	local _device_type="${2:-${MACHINE}}"
	local _final="${3:-no}"
	local _blocks="${4:-"${MACHINE}"}"
	local _work_dir="${5:-"${device_dir}"}"
	local _bootable=${6:-"1"}
	local _balenaos_account="${7:-"balena_os"}"
	local _balenaCloudEmail="${8:-"${balenaCloudEmail}"}"
	local _balenaCloudPassword="${9:-"${balenaCloudPassword}"}"
	local _esr="${10}"
	local _api_env=$(balena_lib_environment)
	local _discontinued

	[ -z "${_device_type}" ] && echo "Device type is required" && return
	_discontinued=$(balena_lib_get_dt_state "${_device_type}")
	if [ "${_discontinued}" = "DISCONTINUED" ]; then
		echo "[INFO]: balena_deploy: Not deploying discontinued device type."
		return
	fi

	[ -z "${_appName}" ] && echo "App name is required" && return
	[ -z "${_blocks}" ] && echo "Block names are required" && return
	_esr=${_esr:-"${ESR}"}
	[ ! -d "${_work_dir}" ] && mkdir "${_work_dir}"

	if [ ! -f "${_work_dir}/balena.yml" ]; then
		if [ -f "${device_dir}/balena.yml" ]; then
			cp "${device_dir}/balena.yml" "${_work_dir}"
		else
			_contract=$(balena_lib_build_contract $(balena_lib_get_slug ${_device_type}))
			cp "${_contract}" "${_work_dir}/balena.yml"
		fi
	fi

	NAMESPACE=${NAMESPACE:-resin}
	if ! balena_lib_docker_pull_helper_image "Dockerfile_balena-push-env" balena_yocto_scripts_revision; then
		return 1
	fi
	docker run --rm -t \
		-e APPNAME="${_appName}" \
		-e API_ENV="${_api_env}" \
		-e BLOCKS="${_blocks}" \
		-e BALENAOS_TOKEN="$(balena_lib_token "${_api_env}")" \
		-e BALENAOS_ACCOUNT="${_balenaos_account}" \
		-e META_BALENA_VERSION="$(balena_lib_get_meta_balena_base_version)" \
		-e RELEASE_VERSION="$(balena_lib_get_os_version)" \
		-e MACHINE="${_device_type}" \
		-e VERBOSE="${VERBOSE}" \
		-e BOOTABLE="${_bootable}" \
		-e FINAL="${_final}" \
		-e ESR="${_esr:-"false"}" \
		-e balenaCloudEmail="${_balenaCloudEmail}" \
		-e balenaCloudPassword="${_balenaCloudPassword}" \
		-e ESR="${_esr}" \
		-v "${device_dir}":/work \
		-v "${_work_dir}":/deploy \
		--privileged \
		"${NAMESPACE}"/balena-push-env:"${balena_yocto_scripts_revision}" /balena-deploy-block.sh

	balena_lib_docker_remove_helper_images "balena-push-env"
}

# Builds the specified block
# Input arguments;
#  $1: App name to deploy into
#  $2: Device type for the app
#  $3: Package list to build the block with
#  $4: Balena cloud account (defaults to balena_os)
#  $5: Balena API environment
#
balena_build_block() {
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
		-e NAMESPACE="${NAMESPACE:-resin}" \
		-e RELEASE_VERSION="$(balena_lib_get_os_version)" \
		-e PACKAGES="${_packages}" \
		-e VERBOSE="${VERBOSE}" \
		-e MACHINE="${_device_type}" \
		-e TAG="${balena_yocto_scripts_revision}" \
		-e WORKSPACE=/work \
		-e balenaCloudEmail="${balenaCloudEmail}" \
		-e balenaCloudPassword="${balenaCloudPassword}" \
		-e ESR="${ESR}" \
		-v "${WORKSPACE:-"${PWD}"}":/work \
		--privileged \
		"${NAMESPACE}"/yocto-block-build-env:"${balena_yocto_scripts_revision}" /balena-build-block.sh

	balena_lib_docker_remove_helper_images "yocto-block-build-env"
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
