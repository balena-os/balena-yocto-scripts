#!/bin/bash
set -e

source /manage-docker.sh

trap 'cleanup fail' SIGINT SIGTERM

# Start docker
echo "[INFO] Starting docker."
dockerd --data-root /scratch/docker > /var/log/docker.log &
wait_docker

_local_image=$(docker load -i /host/resin-image.docker | cut -d: -f1 --complement | tr -d " " )

echo "[INFO] Logging into $deployTo as balenaos"
if [ "$DEPLOY_TO" = "staging" ]; then
	export BALENARC_BALENA_URL=balena-staging.com
	balena login --token $BALENAOS_STAGING_TOKEN
else
	balena login --token $BALENAOS_PRODUCTION_TOKEN
fi

echo "[INFO] Pushing $_local_image to balenaos/$SLUG"
_app_suffix=""
if [ "$ESR" = "true" ]; then
	_app_suffix="-esr"
fi

_releaseID=$(balena deploy "balenaos/$SLUG$_app_suffix" "$_local_image" | sed -n 's/.*Release: //p')
if [ "$DEVELOPMENT_IMAGE" = "yes" ]; then
	_variant="development"
else
	_variant="production"
fi

balena tag set version $VERSION_HOSTOS --release $_releaseID
balena tag set variant $_variant --release $_releaseID

cleanup
exit 0
