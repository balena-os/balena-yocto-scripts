#!/bin/bash

set -e

IMAGE="${IMAGE}"

AMI_NAME="${AMI_NAME}"
AMI_ROOT_DEVICE_NAME=${AMI_ROOT_DEVICE_NAME:-/dev/sda1}
AMI_EBS_DELETE_ON_TERMINATION=${AMI_EBS_DELETE_ON_TERMINATION:-true}
AMI_EBS_VOLUME_SIZE=${AMI_EBS_VOLUME_SIZE:-8}
AMI_EBS_VOLUME_TYPE=${AMI_EBS_VOLUME_TYPE:-gp2}

IMPORT_SNAPSHOT_TIMEOUT_MINS=${IMPORT_SNAPSHOT_TIMEOUT_MINS:-15}
BOOT_PARTITION=''

ensure_all_env_variables_are_set() {
    local env_not_set=""
    local env_variables="AWS_ACCESS_KEY_ID
                         AWS_SECRET_ACCESS_KEY
                         AWS_DEFAULT_REGION
                         S3_BUCKET
                         IMAGE
                         AMI_NAME
                         AMI_ARCHITECTURE
                         BALENA_PRELOAD_APP
                         BALENARC_BALENA_URL
                         BALENACLI_TOKEN
                         PRELOAD_SSH_PUBKEY"

    for env in $env_variables; do
        [[ -z "${!env}" ]] && echo "ERROR: Missing env variable: $env" && env_not_set=true
    done

    if [[ "$env_not_set" ]]; then exit 1; fi
}


mount_cleanup() {
    [[ -n "${BOOT_PARTITION}" ]] && \
        echo "* Unmounting boot partition" && \
        umount "${BOOT_PARTITION}" && \
        rmdir "${BOOT_PARTITION}" && \
        BOOT_PARTITION=''

    [[ -n "${LOOP_DEV}" ]] && \
        echo "* Detaching loop device" && \
        losetup -d "${LOOP_DEV}" && \
        LOOP_DEV=''
}



mount_boot_partition() {
    local img=$1
    local __bootvar=$2
    local __loopvar=$3

    new_dev=$(mktemp -d)
    mount -t devtmpfs devtmpfs "${new_dev}"
    for mnt in console mqueue pts shm
    do
      mount --move "/dev/${mnt}" "${new_dev}/${mnt}"
    done

    umount /dev || :

    mount --move "${new_dev}" /dev

    /lib/systemd/systemd-udevd -d
    udevadm settle

    img_loop_dev=$(losetup -fP --show "${img}")
    echo "* Image attached to ${img_loop_dev}"
    boot_partition_mountpoint=$(mktemp -d)

    mount "${img_loop_dev}p1" "${boot_partition_mountpoint}" > /dev/null 2>&1

    echo "* Boot partition mounted on ${boot_partition_mountpoint}"
    eval "$__bootvar='${boot_partition_mountpoint}'"
    eval "$__loopvar='${img_loop_dev}'"
}

deploy_preload_app_to_image() {

    local image=$1

    echo "* Adding the preload app"
    balena preload \
      --debug \
      --app "${BALENA_PRELOAD_APP}" \
      --commit current \
      "${image}"
}

add_ssh_key_to_boot_partition() {
    local public_key=$1

    echo "* Adding the preload public key"
    cp "${BOOT_PARTITION}/config.json" /tmp/.config.json
    jq --arg keys "${public_key}" '. + {os: {sshKeys: [$keys]}}' "${BOOT_PARTITION}/config.json" > /tmp/.config.json
    mv /tmp/.config.json "${BOOT_PARTITION}/config.json"
    mount_cleanup || true
}

get_value_from_ebs_snapshot_import_task() {
    local task_id=$1
    local field=$2
    aws ec2 describe-import-snapshot-tasks --import-task-ids "${task_id}" | jq -r ".ImportSnapshotTasks[].SnapshotTaskDetail.${field}"
}


aws_s3_image_cleanup() {
    [[ -n "${s3_image_url}" ]] && \
      echo "* Removing img from S3..." && \
      aws s3 rm "${s3_image_url}" && \
      s3_image_url=""
}


aws_ebs_snapshot_cleanup() {
    [[ -n "${ebs_snapshot_id}" ]] && \
      echo "* Removing snapshot from ebs..." && \
      aws ec2 delete-snapshot --snapshot-id "${ebs_snapshot_id}" && \
      ebs_snapshot_id=""
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
    while true; do
        status="$(get_value_from_ebs_snapshot_import_task "${import_task_id}" Status)"
        [[ "$status" == "completed" ]] && break
        [[ "$status" == "deleting" ]]  && \
            error_msg="$(get_value_from_ebs_snapshot_import_task "${import_task_id}" StatusMessage)" && \
            echo "ERROR: Error on import task id ${import_task_id}: '${error_msg}'" && exit 1

        sleep $wait_secs
        secs_waited=$((secs_waited + wait_secs))
        mins_elapsed=$((secs_waited / 60))

        # Show progress every 2 mins (120 secs)
        [[ $((secs_waited % 120)) == 0 ]] && echo "-> Mins elapsed: $mins_elapsed. Progress: $(get_value_from_ebs_snapshot_import_task "${import_task_id}" Progress)%"
        [[ "$mins_elapsed" -ge "$IMPORT_SNAPSHOT_TIMEOUT_MINS" ]] && echo "ERROR: Timeout on import snapshot taksk id ${import_task_id}" && exit 1
    done

    snapshot_id=$(aws ec2 describe-import-snapshot-tasks --import-task-ids "${import_task_id}" | jq -r '.ImportSnapshotTasks[].SnapshotTaskDetail.SnapshotId')
    echo "* AWS import snapshot task complete. SnapshotId: ${snapshot_id}"

    eval "$__snapshot_id='${snapshot_id}'"
    eval "$__s3_image_url='${s3_url}'"
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
        echo "Cleaning up ${existing_image_id}"
        aws ec2 deregister-image --image-id "${existing_image_id}"
    fi

    echo "Creating ${AMI_NAME} AWS AMI image..."
    image_id=$(aws ec2 register-image \
    --name "${AMI_NAME}" \
    --architecture "${AMI_ARCHITECTURE}" \
    --virtualization-type hvm \
    --ena-support \
    --root-device-name "${AMI_ROOT_DEVICE_NAME}" \
    --block-device-mappings "DeviceName=${AMI_ROOT_DEVICE_NAME},Ebs={
                                DeleteOnTermination=${AMI_EBS_DELETE_ON_TERMINATION},
                                SnapshotId=${snapshot_id},
                                VolumeSize=${AMI_EBS_VOLUME_SIZE},
                                VolumeType=${AMI_EBS_VOLUME_TYPE}}" \
    | jq -r .ImageId)

    # If the AMI creation fails, aws-cli will show the error message to the user and we won't get any imageId
    [[ -z "${image_id}" ]] && exit 1

    aws ec2 create-tags --resources "${image_id}" --tags Key=Name,Value="${AMI_NAME}"
    echo "AMI image created with id ${image_id}"

    aws_s3_image_cleanup || true
    aws_ebs_snapshot_cleanup || true

    eval "$__retvalue='$image_id'"
}

cleanup () {
    mount_cleanup || true
    aws_s3_image_cleanup || true
    aws_ebs_snapshot_cleanup || true
}

## MAIN

[[ $(id -u) != 0 ]] && echo "ERROR: This script should be run as root" && exit 1

ensure_all_env_variables_are_set

trap "cleanup" EXIT

balena login -t "${BALENACLI_TOKEN}"

deploy_preload_app_to_image "${IMAGE}"
mount_boot_partition "${IMAGE}" BOOT_PARTITION LOOP_DEV
add_ssh_key_to_boot_partition "${PRELOAD_SSH_PUBKEY}"
create_aws_ebs_snapshot "${IMAGE}" ebs_snapshot_id s3_image_url
# shellcheck disable=SC2154
# ebs_snapshot_id defined with eval in create_aws_ebs_snapshot function
create_aws_ami "${ebs_snapshot_id}" ami_id
