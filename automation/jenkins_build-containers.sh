#!/bin/bash

set -ev

[ -z "${DOCKERFILES}" ] && DOCKERFILES=( Dockerfile_package-based-hostext.template Dockerfile_yocto-build-env Dockerfile_balena-push-env )

# Get the absolute script location
pushd `dirname $0` > /dev/null 2>&1
SCRIPTPATH=`pwd`
popd > /dev/null 2>&1

REVISION=$(cd "${SCRIPTPATH}" && git rev-parse --short HEAD)
NAMESPACE=${NAMESPACE:-resin}

if [ -z "${JOB_NAME}" ]; then
    echo "[ERROR] No job name specified."
    exit 1
fi

for DOCKERFILE in "${DOCKERFILES[@]}"
do
  REPO_NAME=${DOCKERFILE%".template"}
  REPO_NAME=${REPO_NAME#"Dockerfile_"}
  BUILDER="docker"
  BUILDER_OPTS=""
  REPO_NAME="${REPO_NAME}"
  case ${DOCKERFILE} in
    *template)
      BUILDER="balena"
      [ -z "${DEVICE_TYPE}" ] && echo "Device type is required for ${BUILDER} builder." && exit 1
      [ -z "${DEVICE_ARCH}" ] && echo "Device architecture is required for ${BUILDER} builder." && exit 1
      BUILDER_OPTS="--deviceType ${DEVICE_TYPE:?"Device type is required"} --arch ${DEVICE_ARCH:?"Device architecture is required"} --buildArg NAMESPACE=${NAMESPACE}"
      DOCKERFILE_PATH="--dockerfile ${DOCKERFILE}"
      NOCACHE="--nocache"
      REPO_NAME="${DEVICE_TYPE}-${REPO_NAME}"
      TAG="--projectName ${NAMESPACE}/${REPO_NAME}"
      ;;
    *)
      NOCACHE="--no-cache"
      TAG="--tag ${NAMESPACE}/${REPO_NAME}:${REVISION}"
      DOCKERFILE_PATH="-f ${SCRIPTPATH}/${DOCKERFILE}"
      BUILDDER_OPTS="--build-arg NAMESPACE=${NAMESPACE}"
      ;;
  esac
  # Build
  ${BUILDER} build --pull ${NOCACHE} ${BUILDER_OPTS} ${TAG} ${DOCKERFILE_PATH} ${SCRIPTPATH}

  if [ "${BUILDER}" = "balena" ]; then
      docker tag ${NAMESPACE}/${REPO_NAME}_main ${NAMESPACE}/${REPO_NAME}:${REVISION}
  fi
  docker tag ${NAMESPACE}/${REPO_NAME}:${REVISION} ${NAMESPACE}/${REPO_NAME}:latest

  # Push
  docker push ${NAMESPACE}/${REPO_NAME}:${REVISION}
  docker push ${NAMESPACE}/${REPO_NAME}:latest
done
