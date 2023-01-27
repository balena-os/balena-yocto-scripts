#!/bin/bash

[ "${VERBOSE}" = "verbose" ] && set -x

set -e

script_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
# shellcheck disable=SC1091
source "${script_dir}/balena-lib.inc"

AMI_ROOT_DEVICE_NAME=${AMI_ROOT_DEVICE_NAME:-/dev/sda1}
AMI_EBS_DELETE_ON_TERMINATION=${AMI_EBS_DELETE_ON_TERMINATION:-true}
AMI_EBS_VOLUME_SIZE=${AMI_EBS_VOLUME_SIZE:-8}
AMI_EBS_VOLUME_TYPE=${AMI_EBS_VOLUME_TYPE:-gp2}
AMI_BOOT_MODE=${AMI_BOOT_MODE:-uefi}

IMPORT_SNAPSHOT_TIMEOUT_MINS=${IMPORT_SNAPSHOT_TIMEOUT_MINS:-15}

ensure_all_env_variables_are_set() {
    local env_not_set=""
    local env_variables="AWS_ACCESS_KEY_ID
                         AWS_SECRET_ACCESS_KEY
                         AWS_DEFAULT_REGION
                         AWS_SECURITY_GROUP_ID
                         AWS_SUBNET_ID
                         S3_BUCKET
                         IMAGE
                         AMI_NAME
                         AMI_ARCHITECTURE
                         BALENA_PRELOAD_APP
                         BALENARC_BALENA_URL
                         BALENACLI_TOKEN
                         HOSTOS_VERSION
                         MACHINE"

    for env in $env_variables; do
        [ -z "${!env}" ] && echo "ERROR: Missing env variable: $env" && env_not_set=true
    done

    if [ "$env_not_set" = "true" ]; then exit 1; fi
}


deploy_preload_app_to_image() {

    local image=$1

    echo "* Adding the preload app"
    # FIXME: Would you like to disable automatic updates for this fleet now? No
    printf 'n\n' | balena preload \
      --debug \
      --fleet "${BALENA_PRELOAD_APP}" \
      --commit "${BALENA_PRELOAD_COMMIT}" \
      "${image}"
}


get_value_from_ebs_snapshot_import_task() {
    local task_id=$1
    local field=$2
    aws ec2 describe-import-snapshot-tasks --import-task-ids "${task_id}" | jq -r ".ImportSnapshotTasks[].SnapshotTaskDetail.${field}"
}


aws_s3_image_cleanup() {
    [ -n "${s3_image_url}" ] && \
      echo "* Removing img from S3..." && \
      aws s3 rm "${s3_image_url}" && \
      s3_image_url=""
}

create_aws_ebs_snapshot() {

    local img=$1
    local __snapshot_id=$2
    local __s3_image_url=$3

    local snapshot_id
    local status
    local wait_secs=2
    local secs_waited=0
    # https://github.com/koalaman/shellcheck/wiki/SC2155#correct-code-1
    local s3_key
    # Randomize to lower the chance of parallel builds colliding.
    s3_key="tmp-$(basename "${img}")-${RANDOM}"

    # Push to s3 and create the AMI
    echo "* Pushing ${img} to s3://${S3_BUCKET}"
    s3_url="s3://${S3_BUCKET}/preloaded-images/${s3_key}"
    aws s3 cp "${img}" "${s3_url}"

    import_task_id=$(aws ec2 import-snapshot \
      --description "snapshot-${AMI_NAME}" \
      --disk-container "Description=balenaOs,Format=RAW,UserBucket={S3Bucket=${S3_BUCKET},S3Key=preloaded-images/${s3_key}}" | jq -r .ImportTaskId)

    echo "* Created a AWS import snapshot task with id ${import_task_id}. Waiting for completition... (Timeout: $IMPORT_SNAPSHOT_TIMEOUT_MINS mins)"
    eval "$__s3_image_url='${s3_url}'"
    while true; do
        status="$(get_value_from_ebs_snapshot_import_task "${import_task_id}" Status)"
        [ "$status" = "completed" ] && break
        [ "$status" = "deleting" ]  && \
            error_msg="$(get_value_from_ebs_snapshot_import_task "${import_task_id}" StatusMessage)" && \
            echo "ERROR: Error on import task id ${import_task_id}: '${error_msg}'" && exit 1

        sleep $wait_secs
        secs_waited=$((secs_waited + wait_secs))
        mins_elapsed=$((secs_waited / 60))

        # Show progress every 2 mins (120 secs)
        [ $((secs_waited % 120)) = 0 ] && echo "-> Mins elapsed: $mins_elapsed. Progress: $(get_value_from_ebs_snapshot_import_task "${import_task_id}" Progress)%"
        [ "$mins_elapsed" -ge "$IMPORT_SNAPSHOT_TIMEOUT_MINS" ] && echo "ERROR: Timeout on import snapshot taksk id ${import_task_id}" && exit 1
    done

    snapshot_id=$(aws ec2 describe-import-snapshot-tasks --import-task-ids "${import_task_id}" | jq -r '.ImportSnapshotTasks[].SnapshotTaskDetail.SnapshotId')
    echo "* AWS import snapshot task complete. SnapshotId: ${snapshot_id}"

    eval "$__snapshot_id='${snapshot_id}'"
}


create_aws_ami() {

    local snapshot_id=$1
    local __retvalue=$2
    local image_id

    echo "Checking for AMI name conflicts"
    existing_image_id=$(aws ec2 describe-images \
        --filters "Name=name,Values=${AMI_NAME}" \
        --query 'Images[*].[ImageId]' \
        --output text)

    if [ -n "${existing_image_id}" ]; then
        echo "Image ${AMI_NAME} (${existing_image_id}) already exists, this should not happen"
        exit 1
    fi

    # Only supported on x86_64
    if [ "${AMI_ARCHITECTURE}" = "x86_64" ]; then
        TPM="--tpm-support v2.0"
    fi

    echo "Creating ${AMI_NAME} AWS AMI image..."
    image_id=$(aws ec2 register-image \
    --name "${AMI_NAME}" \
    --architecture "${AMI_ARCHITECTURE}" \
    --virtualization-type hvm \
    ${TPM} \
    --ena-support \
    --root-device-name "${AMI_ROOT_DEVICE_NAME}" \
    --boot-mode "${AMI_BOOT_MODE}" \
    --block-device-mappings "DeviceName=${AMI_ROOT_DEVICE_NAME},Ebs={
                                DeleteOnTermination=${AMI_EBS_DELETE_ON_TERMINATION},
                                SnapshotId=${snapshot_id},
                                VolumeSize=${AMI_EBS_VOLUME_SIZE},
                                VolumeType=${AMI_EBS_VOLUME_TYPE}}" \
    | jq -r .ImageId)

    # If the AMI creation fails, aws-cli will show the error message to the user and we won't get any imageId
    [ -z "${image_id}" ] && exit 1

    aws ec2 create-tags --resources "${image_id}" --tags Key=Name,Value="${AMI_NAME}"
    echo "AMI image created with id ${image_id}"

    aws_s3_image_cleanup || true

    eval "$__retvalue='$image_id'"
}

cleanup () {
    aws_s3_image_cleanup || true
    cleanup_eol_amis || true
    rm -f "${CONFIG_JSON}" || true
    balena_cleanup_fleet "${_fleet}" || true
}

balena_setup_fleet() {
    local _config_json="${1}"
    local _ami_test_fleet="${2}"
    local _hostos_version="${3:-${HOSTOS_VERSION}}"
    local _ami_test_org="${4:-testbot}"
    local _device_type="${5:-${MACHINE}}"
    local _uuid
    local _key_file="${HOME}/.ssh/id_ed25519"

    [ -z "${_ami_test_fleet}" ] && _ami_test_fleet=$(openssl rand -hex 4)
    [ -z "${_config_json}" ] && echo "Path to config.json output is required" && return 1

    # Create test fleet
    >&2 echo "Creating ${_ami_test_org}/${_ami_test_fleet}"
    >&2 balena fleet create "${_ami_test_fleet}" --organization "${_ami_test_org}" --type "${_device_type}"

    # Register a key
    mkdir -p "$(dirname "${_key_file}")"
    ssh-keygen -t ed25519 -N "" -q -f "${_key_file}"
    # shellcheck disable=SC2046
    >&2 eval $(ssh-agent)
    >&2 ssh-add
    balena key add "${_ami_test_fleet}" "${_key_file}.pub"

    _uuid=$(balena device register "${_ami_test_org}/${_ami_test_fleet}" | awk '{print $4}')
    >&2 echo "Pre-registered device with UUID ${_uuid}"

    >&2 balena config generate --network ethernet --version "${_hostos_version}" --device "${_uuid}" --appUpdatePollInterval 5 --output "${_config_json}"
    if [ ! -f "${_config_json}" ]; then
      echo "Unable to generate configuration"
      return 1
    else
        _new_uuid=$(jq -r '.uuid' "${_config_json}")
        if [ "${_new_uuid}" != "${_uuid}" ]; then
            echo "Invalid uuid in ${_config_json}"
            return 1
        fi
    fi
    echo "${_ami_test_org}/${_ami_test_fleet}"
}

# shellcheck disable=SC2120
balena_cleanup_fleet() {
    local _fleet="${1}"
    local _key_id
    [ -z "${_fleet}" ] && return
    balena fleet rm "${_fleet}" --yes || true
    _key_id=$(balena keys | grep "${_fleet#*/}" | awk '{print $1}')
    balena key rm "${_key_id}" --yes || true
}

aws_ami_do_public() {
    local _ami_image_id="${1}"
    local _ami_region=${2:-us-east-1}
    local _ami_snapshot_id
    [ -z "${_ami_image_id}" ] && echo "AMI image ID is required" && return
    _ami_snapshot_id=$(aws ec2 describe-images --region="${_ami_region}" --image-ids "${_ami_image_id}" | jq -r '.Images[].BlockDeviceMappings[].Ebs.SnapshotId')
    if [ -n "${_ami_snapshot_id}" ]; then
        if aws ec2 modify-snapshot-attribute --region "${_ami_region}" --snapshot-id "${_ami_snapshot_id}" --attribute createVolumePermission --operation-type add --group-names all; then
            if [ "$(aws ec2 describe-snapshot-attribute --region "${_ami_region}" --snapshot-id "${_ami_snapshot_id}" --attribute createVolumePermission | jq -r '.CreateVolumePermissions[].Group')" == "all" ]; then
                echo "AMI snapshot ${_ami_snapshot_id} is now publicly accessible"
            else
                echo "AMI snapshot ${_ami_snapshot_id} could not be made public"
                return 1
            fi
        fi
    else
        echo "AMI snapshot ID not found"
        return 1
    fi

    if aws ec2 modify-image-attribute \
        --image-id "${_ami_image_id}" \
        --launch-permission "Add=[{Group=all}]"; then
        if [ "$(aws ec2 describe-images --image-ids "${_ami_image_id}" | jq -r '.Images[].Public')" = "true" ]; then
            echo "AMI with ID ${_ami_image_id} is now public"
        else
            echo "Failed to set image with ID ${_ami_image_id} public"
            return 1
        fi
    fi
}

aws_test_instance() {
    local _ami_name="${1}"
    local _uuid="${2}"
    local _config_json="${3}"
    # Name: A public
    local _ami_subnet_id="${4:-subnet-02d18a08ea4058574}"
    # Name: balena-tests-compute
    local _ami_security_group_id="${5:-sg-057937f4d89d9d51c}"
    # Default to a Nitro instance for TPM support
    local _ami_instance_type="${6:-m5.large}"
    local _ami_image_id
    local _instance_id
    local _instance_arch
    local _output=""

    [ -z "${_ami_name}" ] && echo "The AMI to instantiate needs to be defined" && return 1
    [ -z "${_uuid}" ] && echo "The device UUID needs to be defined" && return 1
    [ -z "${_config_json}" ] && echo "The path to config.json needs to be defined" && return 1
    [ -n "${_config_json}" ] && [ ! -f "${_config_json}" ] && echo "${_config_json} does not exist" && return 1

    _ami_image_id=$(aws ec2 describe-images --filters "Name=name,Values=${_ami_name}" --query 'Images[*].[ImageId]' --output text)
    if [ -z "${_ami_image_id}" ]; then
        echo "No ${_ami_name} AMI found."
        exit 1
    fi

    _instance_arch=$(aws ec2 describe-images --image-ids "${_ami_image_id}" | jq -r '.Images[0].Architecture')
    if [ "${_instance_arch}" = "arm64" ]; then
        _ami_instance_type="a1.large"
    fi

    echo "Instantiating ${_ami_image_id} in subnet ${_ami_subnet_id} and security group ${_ami_security_group_id} in ${_ami_instance_type}"
    _instance_id=$(aws ec2 run-instances --image-id "${_ami_image_id}" --count 1 \
        --instance-type "${_ami_instance_type}" \
        --tag-specifications \
        "ResourceType=instance,Tags=[{Key=Name,Value=test-${_ami_name}}]" \
        "ResourceType=volume,Tags=[{Key=Name,Value=test-${_ami_name}}]" \
        --subnet-id "${_ami_subnet_id}" \
        --security-group-ids "${_ami_security_group_id}" \
        --user-data "file://${_config_json}" | jq -r '.Instances[0].InstanceId')
    if [ -z "${_instance_id}" ]; then
        echo "Error instantiating ${_ami_image_id} on ${_ami_instance_type}"
        return 1
    fi

    # Give it time to spin up
    sleep 2m

    # Check supervisor is healthy
    _loops=30
    until echo 'balena ps -q -f name=balena_supervisor | xargs balena inspect | \
        jq -r ".[] | select(.State.Health.Status!=null).Name + \":\" + .State.Health.Status"; exit' | \
        balena ssh "${_uuid}" | grep -q ":healthy"; do
            echo "Waiting for supervisor..."
            sleep "$(( (RANDOM % 30) + 30 ))s";
            _loops=$(( _loops - 1 ))
            if [ ${_loops} -lt 0 ]; then
                echo "Timed out without supervisor health check pass"
                break
            fi
    done

    if [ -n "${_instance_id}" ]; then
        echo "Terminating instance ${_instance_id}"
        aws ec2 terminate-instances --instance-ids "${_instance_id}"
    fi

    if [ ${_loops} -gt 0 ]; then
        # Make AMI public
        if ! aws_ami_do_public "${_ami_image_id}"; then
            exit 1
        fi
    fi
 }

# shellcheck disable=SC2120
cleanup_eol_amis() {
    local _date
    local _snapshots
    local _period=${1:-"2 years ago"}
    _date=$(date +%Y-%m-%d -d "${_period}")
    echo "Cleaning up AMi images older than ${_period}"
    image_ids=$(aws ec2 describe-images \
        --filters "Name=name,Values=${AMI_NAME%%-*}-*" \
        --owners "self" \
        --query 'Images[?CreationDate<`'"${_date}"'`].[ImageId]' --output text)
    for image_id in ${image_ids}; do
        _snapshots="$(aws ec2 describe-images --image-ids "${image_id}" --query 'Images[*].BlockDeviceMappings[*].Ebs.SnapshotId' --output text)"
        if aws ec2 deregister-image --image-id "${image_id}"; then
            echo "De-registered AMI ${image_id}"
            if [ -n "${_snapshots}" ]; then
                for snapshot in ${_snapshots}; do
                    if aws ec2 delete-snapshot --snapshot-id "${snapshot}"; then
                        echo "Removed snapshot ${snapshot}"
                    else
                        echo "Could not remove snapshot ${snapshot}"
                    fi
                done
            fi
        else
            echo "Could not de-register AMI ${image_id}"
        fi
    done
}

## MAIN

! [[ $(id -u) -eq 0 ]] && echo "ERROR: This script should be run as root" && exit 1

ensure_all_env_variables_are_set

trap "cleanup" ERR EXIT

balena login -t "${BALENACLI_TOKEN}"

# shellcheck disable=SC2153
deploy_preload_app_to_image "${IMAGE}"
create_aws_ebs_snapshot "${IMAGE}" ebs_snapshot_id s3_image_url
# shellcheck disable=SC2154
# ebs_snapshot_id defined with eval in create_aws_ebs_snapshot function
create_aws_ami "${ebs_snapshot_id}" ami_id

CONFIG_JSON="$(mktemp)"
_fleet=$(balena_setup_fleet "${CONFIG_JSON}")
UUID=$(jq -r '.uuid' "${CONFIG_JSON}")

if [ -n "${UUID}" ]; then
    aws_test_instance "${AMI_NAME}" "${UUID}" "${CONFIG_JSON}" "${AWS_SUBNET_ID}" "${AWS_SECURITY_GROUP_ID}"
fi
