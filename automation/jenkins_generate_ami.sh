#!/bin/bash

[ "${VERBOSE}" = "verbose" ] && set -x

# Publish to staging by default
S3_ACCESS_KEY=${STAGING_S3_ACCESS_KEY}
S3_SECRET_KEY=${STAGING_S3_SECRET_KEY}
S3_REGION=${STAGING_S3_REGION:-us-east-1}
S3_BUCKET=${STAGING_S3_BUCKET:-resin-staging-img}
BALENACLI_TOKEN=${BALENAOS_STAGING_TOKEN}
BALENA_ENV='balena-staging.com'
AWS_SUBNET_ID="subnet-0d73c1f0da85add17"
AWS_SECURITY_GROUP_ID="sg-09dd285d11b681946"

# shellcheck disable=SC2154
# passed in by Jenkins
if [ "${deployTo}" = 'production' ]; then
    S3_ACCESS_KEY=${PRODUCTION_S3_ACCESS_KEY}
    S3_SECRET_KEY=${PRODUCTION_S3_SECRET_KEY}
    S3_REGION=${PRODUCTION_S3_REGION:-us-east-1}
    S3_BUCKET=${PRODUCTION_S3_BUCKET:-resin-production-img-cloudformation}
    BALENA_ENV='balena-cloud.com'
    BALENACLI_TOKEN=${BALENAOS_PRODUCTION_TOKEN}
    AWS_SUBNET_ID="subnet-02d18a08ea4058574"
    AWS_SECURITY_GROUP_ID="sg-057937f4d89d9d51c"
fi

HELPER_IMAGE_REPO="${HELPER_IMAGE_REPO:-"ghcr.io/balena-os/balena-yocto-scripts"}"

# shellcheck disable=SC1091,SC2154
source "${automation_dir}/include/balena-lib.inc"

if ! balena_lib_docker_pull_helper_image "${HELPER_IMAGE_REPO}" "" "yocto-generate-ami-env" helper_image_id; then
    exit 1
fi

if [ -z "${MACHINE}" ]; then
    echo "MACHINE is required"
    exit 1
fi

YOCTO_IMAGES_PATH="${WORKSPACE}/build/tmp/deploy/images/${MACHINE}"

# TODO: Replace the default value with the value read from the CoffeeScript file once available
if [ -n "${AMI_IMAGE_TYPE}" ] && [ "${AMI_IMAGE_TYPE}" = "installer" ]; then
    IMAGE_NAME=${IMAGE_NAME:-balena-image-flasher-${MACHINE}.balenaos-img}
else
    IMAGE_NAME=${IMAGE_NAME:-balena-image-${MACHINE}.balenaos-img}
fi

ORIG_IMAGE="${YOCTO_IMAGES_PATH}/${IMAGE_NAME}"
PRELOADED_IMAGE="$(mktemp -p "${YOCTO_IMAGES_PATH}")"

cp "${ORIG_IMAGE}" "${PRELOADED_IMAGE}"

# AMI names must be between 3 and 128 characters long, and may contain letters, numbers, '(', ')', '.', '-', '/' and '_'
VERSION=$(cat < "${YOCTO_IMAGES_PATH}/VERSION_HOSTOS" | sed 's/+/-/g')

AMI_SECUREBOOT="false"
if [ -n "${SIGN_API_URL}" ]; then
    AMI_SECUREBOOT="true"
fi

# AMI name format: balenaOS-VERSION-DEVICE_TYPE
# shellcheck disable=SC2154
# passed in by Jenkins
if [ -n "${AMI_IMAGE_TYPE}" ] && [ "${AMI_IMAGE_TYPE}" = "installer" ]; then
    if [ "${AMI_SECUREBOOT}" = "true" ]; then
        AMI_NAME="${AMI_NAME:-balenaOS-${AMI_IMAGE_TYPE}-secureboot-${VERSION}-${MACHINE}}"
    else
        AMI_NAME="${AMI_NAME:-balenaOS-${AMI_IMAGE_TYPE}-${VERSION}-${MACHINE}}"
    fi
else
    AMI_NAME="${AMI_NAME:-balenaOS-${VERSION}-${MACHINE}}"
fi

# TODO: Can get the mapping from somewhere?
JSON_ARCH=$(balena_lib_get_dt_arch "${MACHINE}")
if [ "${JSON_ARCH}" = "amd64" ]; then
    AMI_ARCHITECTURE="x86_64"
elif [ "${JSON_ARCH}" = "aarch64" ]; then
    AMI_ARCHITECTURE="arm64"
fi

APP_SUFFIX="${JSON_ARCH}"
BALENA_PRELOAD_ORG="${BALENA_PRELOAD_ORG:-balena_os}"
BALENA_PRELOAD_APP="${BALENA_PRELOAD_ORG}/cloud-config-${APP_SUFFIX}"
BALENA_PRELOAD_COMMIT="${BALENA_PRELOAD_COMMIT:-current}"

# shellcheck disable=SC1004,SC2154
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
    -e AMI_SECUREBOOT="${AMI_SECUREBOOT}" \
    -e S3_BUCKET="${S3_BUCKET}" \
    -e BALENA_PRELOAD_APP="${BALENA_PRELOAD_APP}" \
    -e BALENARC_BALENA_URL="${BALENA_ENV}" \
    -e BALENACLI_TOKEN="${BALENACLI_TOKEN}" \
    -e BALENA_PRELOAD_COMMIT="${BALENA_PRELOAD_COMMIT}" \
    -e IMAGE="${PRELOADED_IMAGE}" \
    -e MACHINE="${MACHINE}" \
    -e HOSTOS_VERSION="$(balena_lib_get_os_version)" \
    -e AWS_SUBNET_ID="${AWS_SUBNET_ID}" \
    -e AWS_SECURITY_GROUP_ID="${AWS_SECURITY_GROUP_ID}" \
    -w "${WORKSPACE}" \
    "${helper_image_id}" /balena-generate-ami.sh

rm -f "${PRELOADED_IMAGE}"
