#!/bin/bash
set -e

source /manage-docker.sh

trap 'cleanup fail' SIGINT SIGTERM

# Start docker
echo "[INFO] Starting docker."
dockerd --data-root /scratch/docker > /var/log/docker.log &
wait_docker

_local_image=$(docker load -i /host/resin-image.docker | cut -d: -f1 --complement | tr -d " " )
BALENAOS_ACCOUNT="balena_os"

echo "[INFO] Logging into $DEPLOY_TO as ${BALENAOS_ACCOUNT}"
if [ "$DEPLOY_TO" = "staging" ]; then
	export BALENARC_BALENA_URL=balena-staging.com
	balena login --token $BALENAOS_STAGING_TOKEN
else
	balena login --token $BALENAOS_PRODUCTION_TOKEN
fi

_app_suffix=""
if [ "$ESR" = "true" ]; then
	_app_suffix="-esr"
fi

echo "Is this an ESR version? ${ESR}"
echo "[INFO] Pushing $_local_image to ${BALENAOS_ACCOUNT}/$SLUG$_app_suffix"
_releaseID=$(balena deploy "${BALENAOS_ACCOUNT}/$SLUG$_app_suffix" "$_local_image" | sed -n 's/.*Release: //p')
if [ "$DEVELOPMENT_IMAGE" = "yes" ]; then
	_variant="development"
else
	_variant="production"
fi

balena tag set version $VERSION_HOSTOS --release $_releaseID
balena tag set variant $_variant --release $_releaseID
if [ "$ESR" = "true" ]; then
	balena tag set meta-balena-base $META_BALENA_VERSION --release $_releaseID
fi

cleanup
exit 0
