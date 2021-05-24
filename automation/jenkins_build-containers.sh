#!/bin/bash

set -ev

[ -z "${DOCKERFILES}" ] && DOCKERFILES=( Dockerfile_yocto-block-build-env Dockerfile_yocto-build-env Dockerfile_balena-push-env Dockerfile_balena-generate-ami-env )

SCRIPTPATH=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
REVISION=$(cd "${SCRIPTPATH}" && git rev-parse --short=7 HEAD)
NAMESPACE=${NAMESPACE:-resin}

source "${SCRIPTPATH}/include/balena-lib.inc"

balena_lib_dockerhub_login

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
