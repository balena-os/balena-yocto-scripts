#!/bin/bash

set -ev

[ -z "${DOCKERFILES}" ] && DOCKERFILES=( Dockerfile_yocto-block-build-env Dockerfile_yocto-build-env Dockerfile_balena-push-env )

SCRIPTPATH=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
REVISION=$(cd "${SCRIPTPATH}" && git rev-parse --short HEAD)
NAMESPACE=${NAMESPACE:-resin}

DOCKERHUB_USER="${DOCKERHUB_USER:-"balenadevices"}"
DOCKERHUB_PWD=${DOCKERHUB_PWD:-"${balenadevicesDockerhubPassword}"}

if [ -z "${JOB_NAME}" ]; then
    echo "[ERROR] No job name specified."
    exit 1
fi

echo "Login to docker as ${DOCKERHUB_USER}"
docker login -u "${DOCKERHUB_USER}" -p "${DOCKERHUB_PWD}"

for DOCKERFILE in "${DOCKERFILES[@]}"
do
  REPO_NAME=${DOCKERFILE#"Dockerfile_"}
  # Build
  docker build --pull --no-cache --tag ${NAMESPACE}/${REPO_NAME}:${REVISION} -f ${SCRIPTPATH}/${DOCKERFILE} ${SCRIPTPATH}

  # Tag
  docker tag ${NAMESPACE}/${REPO_NAME}:${REVISION} ${NAMESPACE}/${REPO_NAME}:latest

  # Push
  docker push ${NAMESPACE}/${REPO_NAME}:${REVISION}
  docker push ${NAMESPACE}/${REPO_NAME}:latest
done
