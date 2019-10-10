#!/bin/bash

set -ev

DOCKERFILES=( Dockerfile_yocto-build-env Dockerfile_balena-push-env )

REVISION=$(git rev-parse --short HEAD)

# Get the absolute script location
pushd `dirname $0` > /dev/null 2>&1
SCRIPTPATH=`pwd`
popd > /dev/null 2>&1

if [ -z "${JOB_NAME}" ]; then
    echo "[ERROR] No job name specified."
    exit 1
fi

for DOCKERFILE in "${DOCKERFILES[@]}"
do
  REPO_NAME=${DOCKERFILE#"Dockerfile_"}
  # Build
  docker build --pull --no-cache --tag resin/${REPO_NAME}:${REVISION} -f ${SCRIPTPATH}/${DOCKERFILE} ${SCRIPTPATH}

  # Tag
  docker tag resin/${REPO_NAME}:${REVISION} resin/${REPO_NAME}:latest

  # Push
  docker push resin/${REPO_NAME}:${REVISION}
  docker push resin/${REPO_NAME}:latest
done
