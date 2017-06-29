#!/bin/bash

set -ev

DOCKERFILE=Dockerfile_yocto-build-env

# Get the absolute script location
pushd `dirname $0` > /dev/null 2>&1
SCRIPTPATH=`pwd`
popd > /dev/null 2>&1

if [ -z "${REVISION}" ]; then
    echo "[ERROR] No revision specified."
    exit 1
fi

if [ -z "${JOB_NAME}" ]; then
    echo "[ERROR] No job name specified."
    exit 1
fi

# Build
docker build --pull --no-cache --tag resin/${JOB_NAME}:${REVISION} -f ${SCRIPTPATH}/${DOCKERFILE} ${SCRIPTPATH}

# Tag
docker tag -f resin/${JOB_NAME}:${REVISION} resin/${JOB_NAME}:latest

# Push
docker push resin/${JOB_NAME}:${REVISION}
docker push resin/${JOB_NAME}:latest
