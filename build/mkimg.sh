#!/usr/bin/env bash

# abort on nonzero exitstatus
set -o errexit
# don't hide errors within pipes
set -o pipefail
# abort on unbound variable
#set -o nounset
#set -o xtrace

red="\033[1;31m"
green="\033[1;32m"
reset="\033[0m"

readonly script_name=$(basename "${0}")
build_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
include_dir="${build_dir}/../automation/include/"
readonly script_file="${build_dir}/$(basename "${BASH_SOURCE[0]}")"
readonly script_base="$(basename "${script_file}" .sh)"
readonly MSDOS_MAX_PRIMARY_PARTS=4
readonly BALENA_IMAGE_FLAG_FILE="balena-image"
readonly BALENA_PARTITION_PREFIX="resin-"

usage() {
	cat <<EOF
Usage: ${script_name} [OPTIONS]
    -d Device type name
    -i Path to raw image file
    -r OS release version to populate (optional)
    -a Balena environment (defaults to balena-cloud.com)
    -t Balena API token
    -h Display usage
    -v Verbose output
EOF
	exit 0
}

source "${include_dir}/balena-docker.inc"
source "${include_dir}/balena-lib.inc"
source "${include_dir}/balena-api.inc"

error() {
	printf "${red}!!! %s${reset}\\n" "${*}" 1>&2
}

debug() {
	if [ "${verbose}" == "1" ]; then printf "${*}\n" 1>&2; fi
}

__finish() {
	local _partitionIndex=1
	local _partitionCount
	local _result=$?
	# Always finish
	set +e
	[ $_result -ne 0 ] && error "Exiting with error"
	[ -f "${DOCKER_PIDFILE}" ] && balena_docker_stop "noexit" "${DOCKER_PIDFILE}"

	if [ -n "${RAWIMAGEFILE}" ]; then
		_loopDeviceNode=$(losetup -l -n -O "name,back-file" | grep "${RAWIMAGEFILE}" | cut -d ' ' -f 1)
		if [ -n "${_loopDeviceNode}" ]; then
			_partitionCount=$(find /dev -name "$(basename "${_loopDeviceNode}")p*" | wc -l)
			if [ -n "${_partitionCount}" ]; then
				while [ "${_partitionIndex}" -le "${_partitionCount}" ]; do
					_device="${_loopDeviceNode}p${_partitionIndex}"
					__umount_timeout "${_device}" 1
					_partitionIndex=$(( _partitionIndex + 1 ))
				done
			fi
		fi
	fi
	losetup -D > /dev/null 2>&1
	[ -n "${TMPDIR}" ] && rm -rf "${TMPDIR}"
	[ -n "${IMAGEID}" ] && DOCKER_HOST=${DOCKER_HOST} docker rmi "${IMAGEID}"
	exit "${_result}"
}
trap __finish EXIT ERR

# Create a partitioned image according to the corresponding OS contract
#
# Inputs:
#
# $1: Contract's slug
# $2: Path to the output image file
#
create_partitions ()
{
	local _slug="${1}"
	local _rawImageFile="${2}"
	local _partitionStart=0
	local _partitionEnd=0
	local _partitions
	local _partitionName
	local _partitionSize
	local _partitionType
	local _partitionBootable
	local _partitionOffset
	local _partitionAlignment
	local _partitionDetails
	local _partitionCount=1
	local _partitionOptions=""
	local _partitionTableType
	local _units
	local _image_size

	[ -z "${_slug}" ] && return
	[ -z "${_rawImageFile}" ] && return

	if [ -f "${_rawImageFile}" ]; then
		>&2 echo "Output file already exists"
		return 2
	fi
	_image_size=$(balena_lib_contract_get_image_size "${_slug}")
	[ -z "${_image_size}" ] || [ "${_image_size}" = "0" ]  && return

	dd if=/dev/zero of="${_rawImageFile}" bs=1024 count=0 seek="${_image_size}" > /dev/null 2>&1
	_partitionTableType=$(balena_lib_contract_get_partition_table "${_slug}")
	_units=$(balena_lib_contract_get_units "${_slug}")
	parted -s "${_rawImageFile}" mklabel "${_partitionTableType}"

	_partitions=$(balena_lib_contract_get_partitions_list "${_slug}")
	for _partitionName in ${_partitions}; do
		_partitionOptions=""
		_partitionDetails=$(balena_lib_contract_get_part "${_slug}" "${_partitionName}")
		_partitionSize=$(echo "${_partitionDetails}" | jq -r '.size')
		_partitionType=$(echo "${_partitionDetails}" | jq -r '.type')
		_partitionBootable=$(echo "${_partitionDetails}" | jq -r '.bootable')
		_partitionAlignment=$(echo "${_partitionDetails}" | jq -r '.alignment')
		[ "${_partitionAlignment}" = "null" ] && _partitionAlignment=0
		_partitionOffset=$(echo "${_partitionDetails}" | jq -r '.offset')
		if [ "${_partitionOffset}" != "null" ]; then
			_partitionStart=$(( _partitionStart + _partitionOffset))
			_partitionEnd=$(( _partitionEnd + _partitionOffset))
		fi

		debug "[${_partitionCount}:${_partitionName}] Size: ${_partitionSize} Type: ${_partitionType} Bootable: ${_partitionBootable} Alignment: ${_partitionAlignment}"

		if [ "${_partitionTableType}" = "msdos" ]; then
			if [ "${_partitionCount}" -eq "${MSDOS_MAX_PRIMARY_PARTS}" ]; then
				_partitionStart=${_partitionEnd}
				parted -s "${_rawImageFile}" -- unit "${_units}" mkpart extended "${_partitionStart}" -1s > /dev/null 2>&1
			fi
			if [ "${_partitionCount}" -lt "${MSDOS_MAX_PRIMARY_PARTS}" ]; then
				_partitionOptions="${_partitionOptions} primary ${_partitionType}"
			elif [ "${_partitionCount}" -ge "${MSDOS_MAX_PRIMARY_PARTS}" ]; then
				_partitionOptions="${_partitionOptions} logical ${_partitionType}"

				# logical partitions needs an empty alignment.
				_partitionStart=$(( _partitionStart + _partitionAlignment ))
			fi
		elif [ "${_partitionTableType}" = "gpt" ]; then
			_partitionOptions="${_partitionOptions} ${_partitionName}"
		else
			echo "Invalid partition table type ${_partitionTableType}"
			return
		fi

		# Alignment only when not using sectors
		if [ "${_units}" != "s" ] && [ "${_partitionAlignment}" != 0 ]; then
			_partitionSizeAligned=$(( _partitionSize + _partitionAlignment - 1 ))
			_partitionSizeAligned=$(( _partitionSizeAligned - _partitionSizeAligned % _partitionAlignment ))
		else
			_partitionSizeAligned=${_partitionSize}
		fi

		_partitionEnd=$(( _partitionStart + _partitionSizeAligned ))
		if [ "${_units}" = "s" ]; then
			_partitionEnd=$(( _partitionEnd - 1 ))
		fi
		debug "[${_partitionCount}:${_partitionName}] Start ${_partitionStart} End ${_partitionEnd}"
		# shellcheck disable=SC2086
		parted -s "${_rawImageFile}" unit "${_units}" mkpart ${_partitionOptions} "${_partitionStart}" "${_partitionEnd}" > /dev/null 2>&1
		_partitionStart=${_partitionEnd}
		if [ "${_units}" = "s" ]; then
			_partitionStart=$(( _partitionStart + 1 ))
		fi

		if [ "${_partitionBootable}" = "1" ]; then
			partitionBootFlags=$(parted -s "${_rawImageFile}" print | tail -n 2 | tr '\n' ' ' | awk '{print $1}')
			parted -s "${_rawImageFile}" set "${partitionBootFlags}" boot on
		fi

		_partitionCount=$(( _partitionCount + 1 ))
	done
	__format_partitions "${_slug}" "${_rawImageFile}"
}

# Format the given raw image file partitions according to the corresponding OS contract
#
# Inputs:
# $0: Slug to locate the OS contract
# $1: Raw image file with partitions to format
#
# Returns
# 0 on success, other on failure
#
__format_partitions() {
	local _slug="${1}"
	local _rawImageFile="${2}"
	local _loopDeviceNode
	local _partitionDetails
	local _partitionIndex=1
	local _partitionTableType
	local _count

	[ -z "${_rawImageFile}" ] && return 1
	[ -z "${_slug}" ] && return 1

	losetup -Pf "${_rawImageFile}" > /dev/null 2>&1
	_loopDeviceNode=$(losetup -l -n -O "name,back-file" | grep "${_rawImageFile}" | cut -d ' ' -f 1)
	_count=$(echo "${_loopDeviceNode}" | wc -w)
	[ "${_count}" -gt "1" ] && >&2 echo "format_partition: Too many loop mounts: ${_count}" && return

	_partitionTableType=$(balena_lib_contract_get_partition_table "${_slug}")
	[ -z "${_partitionTableType}" ] && return
	_partitions=$(balena_lib_contract_get_partitions_list "${_slug}")
	for _partitionName in ${_partitions}; do
		_partitionDetails=$(balena_lib_contract_get_part "${_slug}" "${_partitionName}")
		_partitionType=$(echo "${_partitionDetails}" | jq -r '.type')
		if [ "${_partitionTableType}" = "msdos" ] && [ ${_partitionIndex} -eq "${MSDOS_MAX_PRIMARY_PARTS}" ]; then
			_partitionIndex=$(( _partitionIndex + 1 ))
		fi

		case "${_partitionType}" in
			"fat32")
				mkfs.vfat -F 32 -n "${_partitionName}" "${_loopDeviceNode}p${_partitionIndex}" > /dev/null 2>&1
				;;
			"ext4")
				mkfs.ext4 -E lazy_itable_init=0,lazy_journal_init=0 -i 8192 -F -L "${_partitionName}" "${_loopDeviceNode}p${_partitionIndex}" > /dev/null 2>&1
				;;
			"raw") ;;
			*)
				error "Unsupported ${_partitionType} "
		esac
		_partitionIndex=$(( _partitionIndex + 1 ))
	done
	losetup -D
	return 0
}

# Installs the provided fileset image
#
# Inputs:
#
# $1: Destination directory
# $2: Fileset image
# $3: Docker host socket (default to DOCKER_HOST)
#
# Returns:
#
# 0 on success, other on failure
#
_install_fileset() {
	local _destDir="${1}"
	local _image="${2}"
	local _docker_host="${3:-${DOCKER_HOST}}"
	local _image_id
	local _container_id
	local _blacklist
	local _item
	local _tmpDir

	_blacklist="dev etc/hostname etc/hosts etc/mtab etc/resolv.conf etc/ proc/ sys/ .dockerenv"
	_image_id=$(balena_docker_image_retrieve "${_image}" "${_docker_host}")
	if _container_id=$( DOCKER_HOST=${_docker_host} docker create "${_image_id}" /bin/sleep infinity); then
		_tmpDir=$(mktemp -d --tmpdir=/tmp)
		# docker cp does not allow copying from /proc, /sys etc so untar and copy
		DOCKER_HOST=${_docker_host} docker export "${_container_id}" > "${_tmpDir}.tar"
		# Remove extra content added by docker create
		for _item in ${_blacklist}; do
			tar --delete -f "${_tmpDir}.tar" "${_item}" > /dev/null 2>&1 || true
		done
		tar xf "${_tmpDir}.tar" --no-same-owner -C "${_destDir}" > /dev/null 2>&1
		rm -rf "${_tmpDir}"
		DOCKER_HOST=${_docker_host} docker rm "${_container_id}" > /dev/null 2>&1
	else
		>&2 echo "_install_fileset: Failed"
	fi
	DOCKER_HOST=${_docker_host} docker rmi -f "${_image_id}" > /dev/null 2>&1
}

# Print filesystem type for specified partition
__get_filesystem_type() {
	local _device="${2}"
	local _fstype
	_fstype=$(lsblk -nlo fstype "${_device}" 2>/dev/null)
	echo "${_fstype}"
}

# Print filesystem label for specified partition
__get_filesystem_label() {
	local _device="${1}"
	local _label
	_label=$(lsblk -nlo label "${_device}" 2>/dev/null)
	echo "${_label}"
}

__do_skip_partition() {
	# Adjust as needed for new blocks
	local _partitionLabel="${1}"
	local skip_partition_list="${BALENA_PARTITION_PREFIX}-rootB ${BALENA_PARTITION_PREFIX}-state"
	local _entry
	for _entry in ${skip_partition_list}; do
		if [ -z "${_partitionLabel}" ] || [ "${_partitionLabel}" = "" ] || [ "${_entry}" = "${_partitionLabel}" ]; then
			return 0
		fi
	done
	return 1
}

# Prepare a directory for hostapp installation
__init_hostapp() {
	local _destdir="${1}"
	local _dir

	for _dir in 'dev' 'etc' 'balena' 'hostapps' 'mnt/state' 'proc' 'run' 'sbin' 'sys' 'tmp'; do
		mkdir -p "${_destdir}/${_dir}"
	done

	touch "${_destdir}/etc/machine-id"
	ln -sf ../current/boot/init "${_destdir}/sbin/init"
	ln -sf current/boot "${_destdir}/boot"
}

# Bootstrap a container image for mobynit to boot
__bootstrap_hostapp() {
	local _destdir="${1}"
	local _image_id"${2}"
	_container_id=$(docker create --volume=/boot "${_image_id}" /bin/sh)
	_bootstrap=$(docker inspect -f "{{range .Mounts}}{{.Destination}} {{.Source}}{{end}}" "${_container_id}" | awk '$1 == "/boot" { print $2 }' | head -n1)
	mkdir -p "${_bootstrap}" "${_destdir}/hostapps/${_container_id}"
	ln -sr "${_bootstrap}" "${_destdir}/hostapps/${_container_id}/boot"
	ln -srf "${_destdir}/hostapps/${_container_id}" "${_destdir}/current"
	echo 1 > "${_destdir}/counter"
}

# Wait on a busy umount loop until unmounted or timed out
__umount_timeout() {
	local _path="${1}"
	local _timeout="${2:-10}"
	_stime=$(date +%s)
	_etime=$(date +%s)
	debug "Unmounting $_path"
	until umount -d "${_path}" > /dev/null 2>&1; do
		if [ "$?" -eq 1 ]; then
			# Not mounted
			return 0
		fi
		if [ $(( _etime - _stime )) -le "${_timeout}" ]; then
			sleep 1
			_etime=$(date +%s)
		else
			>&2 echo "[WARN] Failed to umount ${_path} - lazy unmounting"
			umount -l "${_path}" > /dev/null 2>&1
			return
		fi
	done
}

# Populate the image skeleton provided with the specified release
#
# Inputs:
#
# $1: Path to the skeleton image to populate
# $2: Device type name
# $3: Release version to populate with
# $4: App name containing the OS release (defaults to <device-type>-hostos
populate_image() {
	local _rawImageFile="${1}"
	local _device_type="${2}"
	local _release_version="${3}"
	local _token="${4}"
	local _api_env="${5:-balena-cloud.com}"
	local _appName="${6:-${_device_type}-hostos}"
	local _loopDeviceNode
	local _partitionCount
	local _tmpDir
	local _device
	local _partitionType
	local _partitionLabel
	local _partitionIndex=1
	local _fileset
	local _service
	local _overlay
	local _count
	local _filesetImages
	local _serviceImages
	local _overlayImages
	local _storagePath="docker"
	local _boot_flag

	[ -z "${_rawImageFile}" ] && >&2 echo "populate_image: No image provided" && return

	losetup -Pf "${_rawImageFile}" > /dev/null 2>&1
	sleep 1
	_loopDeviceNode=$(losetup -l -n -O "name,back-file" | grep "${_rawImageFile}" | cut -d ' ' -f 1)
	_count=$(echo "${_loopDeviceNode}" | wc -w)
	[ "${_count}" -gt "1" ] && >&2 echo "format_partition: Too many loop mounts: ${_count}" && return
	_partitionCount=$(find /dev -name "$(basename "${_loopDeviceNode}")*" | wc -l)
	# Keep it short in Ubuntu
	# https://github.com/docker/for-linux/issues/741
	_tmpDir=$(mktemp -d /tmp/XXX)
	export TMPDIR="${_tmpDir}"

	while [ "${_partitionIndex}" -lt "${_partitionCount}" ]; do
		_device="${_loopDeviceNode}p${_partitionIndex}"
		_partitionType=$(__get_filesystem_type "${_device}")
		# Logical partitions in msdos have no partition type
		if [ -z "${_partitionType}" ] && [ "${_partitionIndex}" -gt 3 ]; then
			_partitionIndex=$(( _partitionIndex + 1 ))
			_device="${_loopDeviceNode}p${_partitionIndex}"
		fi
		_partitionLabel=$(__get_filesystem_label "${_device}")
		if __do_skip_partition "${_partitionLabel}"; then
			_partitionIndex=$(( _partitionIndex + 1 ))
			_device="${_loopDeviceNode}p${_partitionIndex}"
			_partitionLabel=$(__get_filesystem_label "${_device}")
			continue
		fi
		_store=${_partitionLabel#"${BALENA_PARTITION_PREFIX}"}
		case ${_store} in
			root*)
				_store="root"
				_storagePath="balena"
				;;
			boot)
				_boot_flag="1"
				;;
			*) ;;
		esac

		_filesetImages=$(balena_api_get_images_for_store_with_class "${_appName}" "${_release_version}" "fileset" "${_store}" "${_api_env}" "${_token}")
		if [ -n "${_filesetImages}" ]; then
			local _tmpDockerDir
			mount "${_device}" "${_tmpDir}"
			if [ "${_boot_flag}" = "1" ]; then
				touch "${_tmpDir}/${BALENA_IMAGE_FLAG_FILE}"
			fi
			_tmpDockerDir=$(mktemp -d /tmp/XXX)
			mkdir -p "${_tmpDockerDir}/data"
			# Start docker with --iptables=false and --ip-masq=false not to mess with the host iptables rules
			read -r DOCKER_HOST DOCKER_PIDFILE <<< "$(balena_docker_start "${_tmpDockerDir}/data" "${_tmpDockerDir}" "/dev/null" "false" "false")"
			export DOCKER_HOST
			export DOCKER_PIDFILE
			balena_docker_wait "${DOCKER_HOST}"
			for _fileset in ${_filesetImages}; do
				_install_fileset "${_tmpDir}" "${_fileset}"
			done
			balena_docker_stop "noexit" "${DOCKER_PIDFILE}"
			rm -rf "${_tmpDockerDir}"
			__umount_timeout "${_device}" 10
		fi
		_serviceImages=$(balena_api_get_images_for_store_with_class "${_appName}" "${_release_version}" "service" "${_store}" "${_api_env}" "${_token}")
		_bootableServiceImages=$(balena_api_get_images_for_store_with_class "${_appName}" "${_release_version}" "service" "${_store}" "${_api_env}" "${_token}" "true")
		_overlayImages=$(balena_api_get_images_for_store_with_class "${_appName}" "${_release_version}" "overlay" "${_store}" "${_api_env}" "${_token}")
		if [ -n "${_serviceImages}" ] || [ -n "${_overlayImages}" ] || [ -n "${_bootableServiceImages}" ]; then
			local _data_dir
			local _image_id
			local _base_data_dir
			local _etime
			local _stime
			local _timeout
			local _bootable_service
			_base_data_dir="${_tmpDir}/data"
			_data_dir="${_base_data_dir}/${_storagePath}"
			mkdir -p "${_data_dir}"
			mount "${_device}" "${_base_data_dir}"
			# Start docker with --iptables=false and --ip-masq=false not to mess with the host iptables rules
			read -r DOCKER_HOST DOCKER_PIDFILE <<< "$(balena_docker_start "${_data_dir}" "${_tmpDir}" "/dev/null" "false" "false")"
			export DOCKER_HOST
			export DOCKER_PIDFILE
			balena_docker_wait "${DOCKER_HOST}"
			for _service in ${_serviceImages}; do
				_image_id=$(balena_docker_image_retrieve "${_service}")
				debug "populate_image: Installed ${_service}"
			done
			for _bootable_service in ${_bootableServiceImages}; do
				__init_hostapp "${_base_data_dir}"
				_image_id=$(balena_docker_image_retrieve "${_bootable_service}")
				debug "populate_image: Installed bootable ${_bootable_service}"
				__bootstrap_hostapp "${_base_data_dir}" "${_image_id}"
			done
			for _overlay in ${_overlayImages}; do
				_image_id=$(balena_docker_image_retrieve "${_overlay}")
				debug "populate_image: Installed ${_overlay}"
			done
			balena_docker_stop "noexit" "${DOCKER_PIDFILE}"
			__umount_timeout "${_base_data_dir}" 10
		fi
		_partitionIndex=$(( _partitionIndex + 1 ))
	done
	losetup -D
	rm -rf "${_tmpDir}"
}

main() {
	local _device_type
	local _rawImageFile
	local _slug="balenaos"
	## Sanity checks
	verbose=0
	if [ ${#} -lt 1 ] ; then
		usage
		exit 1
	else
		while getopts "hvd:i:r:a:t:" c; do
			case "${c}" in
				d) _device_type="${OPTARG}";;
				i) _rawImageFile="${OPTARG:-balena-image.img}";;
				r) _release_version="${OPTARG}";;
				a) _api_env="${OPTARG}";;
				t) _token="${OPTARG}";;
				h) usage;;
				v) verbose=1;;
				*) usage;exit 1;;
			esac
		done

		if [ $EUID -ne 0 ]; then
			echo "This script must be run as root"
			exit 1
		fi

		[ -z "${_device_type}" ] && error "Device type required" && exit 2
		if ! balena_lib_contract_is_device_compatible "${_slug}" "${_device_type}"; then
			error "Device type not compatible"
			return
		fi

		if [ -z "${_token}" ]; then
			if [ -f "${HOME}/.balena/token" ]; then
				_token=$(cat "${HOME}/.balena/token")
			else
				>&2 echo "Please authenticate with Balena cloud"
				return
			fi
		fi

		_rawImageFile="${_rawImageFile:-balena-image.img}"
		export RAWIMAGEFILE="${_rawImageFile}"
		echo "Creating bootable ${_rawImageFile}"
		create_partitions "${_slug}" "${_rawImageFile}"
		if [ -n "${_release_version}" ]; then
			populate_image "${_rawImageFile}" "${_device_type}" "${_release_version}" "${_token}" "${_api_env}"
		fi
		printf "Done!\n"
	fi
}

main "${@}"
