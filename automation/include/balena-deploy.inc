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
	local _machine


	[ ! -f "${_device_type_json}" ] && echo "[balena_deploy_artifacts] Device type JSON not found" && return

	_deploy_artifact=$(jq --raw-output '.yocto.deployArtifact' "${_device_type_json}")
	_image=$(jq --raw-output '.yocto.image' "${_device_type_json}")
	_deploy_flasher_artifact=$(jq --raw-output '.yocto.deployFlasherArtifact // empty' "${_device_type_json}")
	_deploy_raw_artifact=$(jq --raw-output '.yocto.deployRawArtifact // empty' "${_device_type_json}")
	_compressed=$(jq --raw-output '.yocto.compressed' "${_device_type_json}")
	_archive=$(jq --raw-output '.yocto.archive' "$_device_type_json")
	_machine=$(jq --raw-output '.yocto.machine' "${_device_type_json}")
	_yocto_build_deploy="${device_dir}/build/tmp/deploy/images/${_machine}"
	_yocto_licenses_deploy="${device_dir}/build/tmp/deploy/licenses/"
	_slug=$(jq --raw-output '.slug' "${_device_type_json}")

	[ -z "${_preserve_build}" ] && rm -rf "${_deploy_dir}"
	mkdir -p "${_deploy_dir}/image"

	cp -v "$_device_type_json" "$_deploy_dir/device-type.json"

	cp -v "$_yocto_build_deploy/VERSION" "$_deploy_dir"
	cp -v "$_yocto_build_deploy/VERSION_HOSTOS" "$_deploy_dir"
	cp -v "$(readlink --canonicalize "$_yocto_build_deploy/$_image-${_machine}.manifest")" "$_deploy_dir/$_image-$_machine.manifest"
	cp -v "$(readlink --canonicalize "$_yocto_build_deploy/balena-image-$_machine.docker")" "$_deploy_dir/balena-image.docker"

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
}
