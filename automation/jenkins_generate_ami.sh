#/bin/bash


# Publish to staging by default
S3_ACCESS_KEY=${STAGING_S3_ACCESS_KEY}
S3_SECRET_KEY=${STAGING_S3_SECRET_KEY}
S3_REGION=${STAGING_S3_REGION:-us-east-1}
BALENA_PRELOAD_SSH_PUBKEY=${PRELOAD_SSH_PUBKEY_STAGING}
BALENACLI_TOKEN=${BALENAOS_STAGING_TOKEN}
BALENA_ENV="balena-staging.com"

if [ "$deployTo" = "production" ]; then
    S3_ACCESS_KEY=${PRODUCTION_S3_ACCESS_KEY}
    S3_SECRET_KEY=${PRODUCTION_S3_SECRET_KEY}
    S3_REGION=${PRODUCTION_S3_REGION:-us-east-1}
    BALENA_PRELOAD_SSH_PUBKEY=${PRELOAD_SSH_PUBKEY_PRODUCTION}
    BALENACLI_TOKEN=${BALENAOS_PRODUCTION_TOKEN}
    BALENA_ENV="balena-cloud.com"
fi

MACHINE=${JOB_NAME#yocto-}
YOCTO_IMAGES_PATH="$WORKSPACE/build/tmp/deploy/images/${MACHINE}"

# TODO: Replace the default value with the value read from the CoffeeScript file once available
IMAGE_NAME=${IMAGE_NAME:-resin-image-genericx86-64-ext.resinos-img}

IMAGE="${YOCTO_IMAGES_PATH}/${IMAGE_NAME}"
VERSION=$(cat ${YOCTO_IMAGES_PATH}/VERSION_HOSTOS)

# AMI name format: balenaOS-VERSION-VARIANT-DEVICE_TYPE
AMI_NAME="balenaOS-${VERSION}-${buildFlavor}-${MACHINE}"

# AWS_SESSION_TOKEN only needed if MFA is enabled for the account
docker run -it --rm                                                     \
    --privileged                                                        \
    --network host                                                      \
    -v ${WORKSPACE}:${WORKSPACE}                                        \
    -v /var/run/docker.sock:/var/run/docker.sock                        \
    -e AWS_ACCESS_KEY_ID=${S3_ACCESS_KEY}                               \
    -e AWS_SECRET_ACCESS_KEY=${S3_SECRET_KEY}                           \
    -e AWS_DEFAULT_REGION=${S3_REGION}                                  \
    -e AWS_SESSION_TOKEN=${S3_SESSION_TOKEN}                            \
    -e AMI_NAME=${AMI_NAME}                                             \
    -e S3_BUCKET=${S3_BUCKET}                                           \
    -e BALENARC_BALENA_URL=${BALENA_ENV}                                \
    -e BALENACLI_TOKEN=${BALENAOS_STAGING_TOKEN}                        \
    -e PRELOAD_SSH_PUBKEY="$BALENA_PRELOAD_SSH_PUBKEY"                  \
    -e IMAGE="${IMAGE}"                                                 \
    -w $WORKSPACE                                                       \
    resin/balena-push-env /bin/bash -c ' \
        apt update && apt install -y python3-pip && pip3 install awscli
        ./generate_ami.sh '
