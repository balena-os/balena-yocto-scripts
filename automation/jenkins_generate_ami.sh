#!/bin/bash

[ "${VERBOSE}" = "verbose" ] && set -x

# Publish to staging by default
S3_ACCESS_KEY=${STAGING_S3_ACCESS_KEY}
S3_SECRET_KEY=${STAGING_S3_SECRET_KEY}
S3_REGION=${STAGING_S3_REGION:-us-east-1}
S3_BUCKET=${STAGING_S3_BUCKET:-resin-staging-img}
BALENA_PRELOAD_SSH_PUBKEY=${PRELOAD_SSH_PUBKEY_STAGING}
BALENACLI_TOKEN=${BALENAOS_STAGING_TOKEN}
BALENA_ENV='balena-staging.com'

# shellcheck disable=SC2154
# passed in by Jenkins
if [ "${deployTo}" = 'production' ]; then
    S3_ACCESS_KEY=${PRODUCTION_S3_ACCESS_KEY}
    S3_SECRET_KEY=${PRODUCTION_S3_SECRET_KEY}
    S3_REGION=${PRODUCTION_S3_REGION:-us-east-1}
    S3_BUCKET=${PRODUCTION_S3_BUCKET:-resin-production-img-cloudformation}
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

ORIG_IMAGE="${YOCTO_IMAGES_PATH}/${IMAGE_NAME}"
PRELOADED_IMAGE="${ORIG_IMAGE}.preloaded"

cp "${ORIG_IMAGE}" "${PRELOADED_IMAGE}"

# AMI names must be between 3 and 128 characters long, and may contain letters, numbers, '(', ')', '.', '-', '/' and '_'
VERSION=$(cat "${YOCTO_IMAGES_PATH}/VERSION_HOSTOS" | sed 's/+/-/g')

# AMI name format: balenaOS-VERSION-VARIANT-DEVICE_TYPE
# shellcheck disable=SC2154
# passed in by Jenkins
AMI_NAME="balenaOS-${VERSION}-${buildFlavor}-${MACHINE}"

# TODO: Can get the mapping from somewhere?
JSON_ARCH=$(jq --raw-output ".arch" "${WORKSPACE}/${MACHINE}.json")
if [ "${JSON_ARCH}" = "amd64" ]; then
    AMI_ARCHITECTURE="x86_64"
elif [ "${JSON_ARCH}" = "aarch64" ]; then
    AMI_ARCHITECTURE="arm64"
fi

APP_SUFFIX=${MACHINE#generic-}
BALENA_PRELOAD_APP="cloud-config-${APP_SUFFIX}"

# shellcheck disable=SC1004
# AWS_SESSION_TOKEN only needed if MFA is enabled for the account
docker run --rm -t \
    --privileged  \
    --network host  \
    -v "${WORKSPACE}:${WORKSPACE}" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -e VERBOSE="${VERBOSE}" \
    -e AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY}" \
    -e AWS_SECRET_ACCESS_KEY="${S3_SECRET_KEY}" \
    -e AWS_DEFAULT_REGION="${S3_REGION}" \
    -e AWS_SESSION_TOKEN="${S3_SESSION_TOKEN}" \
    -e AMI_NAME="${AMI_NAME}" \
    -e AMI_ARCHITECTURE="${AMI_ARCHITECTURE}" \
    -e S3_BUCKET="${S3_BUCKET}" \
    -e BALENA_PRELOAD_APP="${BALENA_PRELOAD_APP}" \
    -e BALENARC_BALENA_URL="${BALENA_ENV}" \
    -e BALENACLI_TOKEN="${BALENACLI_TOKEN}" \
    -e PRELOAD_SSH_PUBKEY="${BALENA_PRELOAD_SSH_PUBKEY}" \
    -e IMAGE="${PRELOADED_IMAGE}" \
    -w "${WORKSPACE}" \
    "${NAMESPACE}/balena-generate-ami-env:${balena_yocto_scripts_revision}" /balena-generate-ami.sh

rm -f "${PRELOADED_IMAGE}"
