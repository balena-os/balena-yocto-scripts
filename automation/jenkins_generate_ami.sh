#!/bin/bash

# Publish to staging by default
S3_ACCESS_KEY=${STAGING_S3_ACCESS_KEY}
S3_SECRET_KEY=${STAGING_S3_SECRET_KEY}
S3_REGION=${STAGING_S3_REGION:-us-east-1}
S3_BUCKET=${STAGING_S3_BUCKET:-resin-staging-img/images}
BALENA_PRELOAD_SSH_PUBKEY=${PRELOAD_SSH_PUBKEY_STAGING}
BALENACLI_TOKEN=${BALENAOS_STAGING_TOKEN}
BALENA_ENV='balena-staging.com'

# shellcheck disable=SC2154
# passed in by Jenkins
if [ "${deployTo}" = 'production' ]; then
    S3_ACCESS_KEY=${PRODUCTION_S3_ACCESS_KEY}
    S3_SECRET_KEY=${PRODUCTION_S3_SECRET_KEY}
    S3_REGION=${PRODUCTION_S3_REGION:-us-east-1}
    S3_BUCKET=${PRODUCTION_S3_BUCKET:-resin-production-img-cloudformation/images}
    BALENA_PRELOAD_SSH_PUBKEY=${PRELOAD_SSH_PUBKEY_PRODUCTION}
    BALENACLI_TOKEN=${BALENAOS_PRODUCTION_TOKEN}
    BALENA_ENV='balena-cloud.com'
fi

NAMESPACE=${NAMESPACE:-resin}

source "${automation_dir}/include/balena-lib.inc"

if ! balena_lib_docker_pull_helper_image "Dockerfile_balena-generate-ami-env" balena_yocto_scripts_revision; then
    exit 1
fi

MACHINE=${JOB_NAME#yocto-}
YOCTO_IMAGES_PATH="${WORKSPACE}/build/tmp/deploy/images/${MACHINE}"

# TODO: Replace the default value with the value read from the CoffeeScript file once available
IMAGE_NAME=${IMAGE_NAME:-balena-image-${MACHINE}.balenaos-img}

IMAGE="${YOCTO_IMAGES_PATH}/${IMAGE_NAME}"
VERSION=$(cat "${YOCTO_IMAGES_PATH}/VERSION_HOSTOS")

# AMI name format: balenaOS-VERSION-VARIANT-DEVICE_TYPE
# shellcheck disable=SC2154
# passed in by Jenkins
AMI_NAME="balenaOS-${VERSION}-${buildFlavor}-${MACHINE}"

APP_SUFFIX=${MACHINE#generic-}
BALENA_PRELOAD_APP="cloud-config-${APP_SUFFIX}"

# shellcheck disable=SC1004
# AWS_SESSION_TOKEN only needed if MFA is enabled for the account
docker run --rm -t \
    --privileged  \
    --network host  \
    -v "${WORKSPACE}:${WORKSPACE}" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -e AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY}" \
    -e AWS_SECRET_ACCESS_KEY="${S3_SECRET_KEY}" \
    -e AWS_DEFAULT_REGION="${S3_REGION}" \
    -e AWS_SESSION_TOKEN="${S3_SESSION_TOKEN}" \
    -e AMI_NAME="${AMI_NAME}" \
    -e S3_BUCKET="${S3_BUCKET}" \
    -e BALENA_PRELOAD_APP="${BALENA_PRELOAD_APP}" \
    -e BALENARC_BALENA_URL="${BALENA_ENV}" \
    -e BALENACLI_TOKEN="${BALENACLI_TOKEN}" \
    -e PRELOAD_SSH_PUBKEY="${BALENA_PRELOAD_SSH_PUBKEY}" \
    -e IMAGE="${IMAGE}" \
    -w "${WORKSPACE}" \
    "${NAMESPACE}/balena-generate-ami-env:${balena_yocto_scripts_revision}" /balena-generate-ami.sh
