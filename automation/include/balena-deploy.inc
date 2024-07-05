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
	local _yocto_build_deploy
	local _yocto_licenses_deploy
	local _slug


	[ ! -f "${_device_type_json}" ] && echo "[balena_deploy_artifacts] Device type JSON not found" && return

	_deploy_artifact=$(jq --raw-output '.yocto.deployArtifact' "${_device_type_json}")
	_image=$(jq --raw-output '.yocto.image' "${_device_type_json}")
	_deploy_flasher_artifact=$(jq --raw-output '.yocto.deployFlasherArtifact // empty' "${_device_type_json}")
	_deploy_raw_artifact=$(jq --raw-output '.yocto.deployRawArtifact // empty' "${_device_type_json}")
	_compressed=$(jq --raw-output '.yocto.compressed' "${_device_type_json}")
	_archive=$(jq --raw-output '.yocto.archive' "$_device_type_json")
	_yocto_build_deploy="${device_dir}/build/tmp/deploy/images/${_device_type}"
	_yocto_licenses_deploy="${device_dir}/build/tmp/deploy/licenses/"
	_slug=$(jq --raw-output '.slug' "${_device_type_json}")

	[ -z "${_preserve_build}" ] && rm -rf "${_deploy_dir}"
	mkdir -p "${_deploy_dir}/image"

	cp -v "$_device_type_json" "$_deploy_dir/device-type.json"

	cp -v "$_yocto_build_deploy/VERSION" "$_deploy_dir"
	cp -v "$_yocto_build_deploy/VERSION_HOSTOS" "$_deploy_dir"
	cp -v "$(readlink --canonicalize "$_yocto_build_deploy/$_image-${_device_type}.manifest")" "$_deploy_dir/$_image-$_device_type.manifest"
	cp -v "$(readlink --canonicalize "$_yocto_build_deploy/balena-image-$_device_type.docker")" "$_deploy_dir/balena-image.docker"

	if [ -d "${_yocto_licenses_deploy}" ]; then
		tar -czf "${_deploy_dir}/licenses.tar.gz" -C $(dirname "${_yocto_licenses_deploy}") $(basename "${_yocto_licenses_deploy}")
	fi
	if [ -f "${device_dir}/CHANGELOG.md" ]; then
		cp -v "${device_dir}/CHANGELOG.md" "${_deploy_dir}"
	fi

	if [ -d "$_yocto_build_deploy/usbboot" ]; then
		cp -rv "$_yocto_build_deploy/usbboot" "$_deploy_dir" || true
	fi

	if [ -d "$_yocto_build_deploy/rpi-eeprom/secure-boot-lock" ]; then
		cp -rv "$_yocto_build_deploy/rpi-eeprom/secure-boot-lock" "$_deploy_dir" || true
	fi

	test "${_slug}" = "edge" && return

	if [ "$_deploy_artifact" = "docker-image" ]; then
		echo "[WARN] No artifacts to deploy. The images will be pushed to docker registry."
		return
	fi

	if [ -f "$_yocto_build_deploy/kernel_modules_headers.tar.gz" ]; then
		cp -v "$_yocto_build_deploy/kernel_modules_headers.tar.gz" "$_deploy_dir" || true
	fi
	if [ -f "$_yocto_build_deploy/kernel_source.tar.gz" ]; then
		cp -v "$_yocto_build_deploy/kernel_source.tar.gz" "$_deploy_dir" || true
	fi
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

# Deploy artifacts to S3
#
# Inputs:
#
# $1: Device type name
# $2: ESR flag
# $3: S3 environmennt to deploy to (production | staging ) (defaults to production)
# $4: Helper image repository
#
balena_deploy_to_s3() {
	local _device_type="${1}"
	local _esr=${2}
	local _deploy_to="${3:-"production"}"
	local _image_repo="${4}"
	local _slug
	local _artifact
	local _s3_bucket
	local _s3_bucket_prefix
	local _s3_bucket_suffix
	local _is_private
	local _s3_version_hostos="$(balena_lib_get_os_version)"

	_slug=$(balena_lib_get_slug "${_device_type}")
	_artifact=$(balena_lib_get_deploy_artifact "${_device_type}")

	[ -z "${_device_type}" ] && echo "[balena_deploy_to_s3] Device type is required" && return 1
	[ -z "${_s3_version_hostos}" ] && echo "[balena_deploy_to_s3] No hostOS version found" && return 1

	[ -z "${_image_repo}" ] && _image_repo="${HELPER_IMAGE_REPO:-"ghcr.io/balena-os/balena-yocto-scripts"}"
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
	elif [ -z "${_is_private}" ] || [ "${_is_private}" = "null" ]; then
		# If _is_private is empty, or a null value, the curl to retrieve it has failed
		echo "[ERROR] Device type not found..."
		return 1
	fi

	local _s3_cmd="s4cmd --access-key=${_s3_access_key} --secret-key=${_s3_secret_key} --API-ServerSideEncryption=AES256"
	local _s3_sync_opts="--recursive --API-ACL=${_s3_policy}"
	if ! balena_lib_docker_pull_helper_image "balena/balena-img" "6.20.26" "" helper_image_id; then
		return 1
	fi
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
		-v "$_s3_deploy_dir":/host/images "${helper_image_id}" /bin/sh -e -c ' \
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
if [ "$DEPLOY_ARTIFACT" = "docker-image" ]; then
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

# Builds and deploys the specified block to BalenaCloud
# Input arguments;
#  $1: App name to deploy into
#  $2: Device type for the app
#  $3: Bootable flag
#  $4: Path to the image to deploy
#  $5: Deploy release to S3 and balenaCloud fleet
#  $6: Deploy to balenaCloud fleet as draft (default) or final release
#  $7: secureBoot feature flag
#      - if set to yes this adds the secureBoot feature flag into the OS contract
#      - needed for other components to identify secureBoot compatible software releases
#  $8: Path to the working directory (defaults to device repository root)
#  $9: BalenaCloud admin account (defaults to balena_os)
#  $10: BalenaCloud email address (defaults to the balenaCloudEmail enviromental variable)
#  $11: BalenaCloud password (defaults to the balenaCloudPassword enviromental variable)
#  $12: ESR release flag (default to "ESR" environment variable)
#  $13: Version of the helper image that is used to deploy the block
#
balena_deploy_block() {
	local _appName="$1"
	local _device_type="${2:-${MACHINE}}"
	local _bootable=${3:-"0"}
	local _image_path="${4:-""}"
	local _deploy="${5:-no}"
	local _final="${6:-no}"
	local _sb_feature_flag="${7:-no}"
	local _work_dir="${8:-"${device_dir}"}"
	local _balenaos_account="${9:-"balena_os"}"
	local _balenaCloudEmail="${10:-"${balenaCloudEmail}"}"
	local _balenaCloudPassword="${11:-"${balenaCloudPassword}"}"
	local _esr="${12}"
	local _helperImageVersion="${13:-"${BALENA_YOCTO_SCRIPTS_VERSION}"}"
	local _api_env=$(balena_lib_environment)

	[ -z "${_device_type}" ] && echo "Device type is required" && return

	[ -z "${_appName}" ] && echo "App name is required" && return
	if [ -f "${_image_path}" ]; then
		_image_path="$(readlink --canonicalize "${_image_path}")"
	fi
	_esr=${_esr:-"${ESR}"}

	if [ ! -f "${_work_dir}/balena.yml" ]; then
		if [ -f "${device_dir}/balena.yml" ]; then
			cp "${device_dir}/balena.yml" "${_work_dir}"
		else
			_contract=$(balena_lib_build_contract $(balena_lib_get_slug ${_device_type}))
			cp "${_contract}" "${_work_dir}/balena.yml"
		fi
	fi

	HELPER_IMAGE_REPO="${HELPER_IMAGE_REPO:-"ghcr.io/balena-os/balena-yocto-scripts"}"
	if ! balena_lib_docker_pull_helper_image "${HELPER_IMAGE_REPO}" "" "balena-push-env" helper_image_id; then
		return 1
	fi
	docker run --rm -t \
		-e APPNAME="${_appName}" \
		-e API_ENV="${_api_env}" \
		-e BALENAOS_TOKEN="$(balena_lib_token "${_api_env}")" \
		-e BALENAOS_ACCOUNT="${_balenaos_account}" \
		-e META_BALENA_VERSION="$(balena_lib_get_meta_balena_base_version)" \
		-e RELEASE_VERSION="$(balena_lib_get_os_version)" \
		-e MACHINE="${_device_type}" \
		-e VERBOSE="${VERBOSE}" \
		-e BOOTABLE="${_bootable}" \
		-e DEPLOY="${_deploy}" \
		-e FINAL="${_final}" \
		-e ESR="${_esr:-"false"}" \
		-e SECURE_BOOT_FEATURE_FLAG="${_sb_feature_flag:-"no"}" \
		-e balenaCloudEmail="${_balenaCloudEmail}" \
		-e balenaCloudPassword="${_balenaCloudPassword}" \
		-e ESR="${_esr}" \
		-e BALENA_YOCTO_SCRIPTS_VERSION="${_helperImageVersion}" \
		-v "${_image_path}":/host/appimage.docker \
		-v "${device_dir}":/work \
		-v "${_work_dir}":/deploy \
		--privileged \
		"${helper_image_id}" /balena-deploy-block.sh

	balena_lib_docker_remove_helper_images "${HELPER_IMAGE_REPO}"
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
	_version=${_version:-$(balena_lib_get_os_version)}
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
		# Container images created by importing a tarball and saving (like the Yocto docker image class does) do not contain labels
		# Hence, if no labels are found default to hostapp values, class service, root store and bootable.
		_class=$(balena_lib_get_label_from_image "${_image_id}" "${BALENA_HOSTOS_BLOCK_CLASS}")
		[ -z "${_class}" ] && class="service"
		_store=$(balena_lib_get_label_from_image "${_image_id}" "${BALENA_HOSTOS_BLOCK_STORE}")
		[ -z "${_store}" ] && _store="root"
		_reboot_required=$(balena_lib_get_label_from_image "${_image_id}" "${BALENA_HOSTOS_BLOCK_REQUIRES_REBOOT}")
		[ -z "${_reboot_required}" ] && _reboot_required="1"
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
# $4: Release final version
# $5: Balena API environment (default to balena-cloud.com)
# $6: Balena API token (defaults to ~/.balena/token)
# $7: Balena cloud account (defaults to balena_os)
# $8: Bootable 0 or 1 (default)
#
# Outputs:
#    None
#
balena_deploy_hostos() {
	local _appName="$1"
	local _blocks="$2"
	local _device_type="$3"
	local _final="${4:-no}"
	local _apiEnv="$5"
	local _token="$6"
	local _account="$7"
	local _bootable="${8:-1}"
	local _path
	local _version

	_apiEnv=${_apiEnv:-"$(balena_lib_environment)"}
	_account=${_account:-"balena_os"}
	_token=${_token:-"$(balena_lib_token "${_apiEnv}")"}
	_version=$(balena_lib_get_os_version)
	[ -z "${_version}" ] && >&2 echo "Invalid version" && return
	[ -z "${_device_type}" ] && >&2 echo "Required device type" && return
	_path=$(__create_compose_file "${_device_type}" "${_apiEnv}" "${_version}" "${_token}" "${_blocks}")
	if [ ! -f "${_path}/docker-compose.yml" ]; then
		>&2 echo "No compose file in ${_path}"
		return
	fi
	balena_deploy_block "${_appName}" "${_device_type}" "${_bootable}" "${_path}"
}
