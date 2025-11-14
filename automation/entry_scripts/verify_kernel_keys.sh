#!/bin/bash
set -e

VERBOSE=${VERBOSE:-0}
[ "${VERBOSE}" = "verbose" ] && set -x

source /balena-docker.inc

trap 'balena_docker_stop fail' SIGINT SIGTERM

INSTALL_DIR="/work"

# Create the normal user to be used for bitbake (barys)
echo "[INFO] Creating and setting builder user $BUILDER_UID:$BUILDER_GID."
groupadd -g $BUILDER_GID builder
if ! cat "/etc/group" | grep docker > /dev/null; then  groupadd docker; fi
useradd -m -u $BUILDER_UID -g $BUILDER_GID -G docker builder && newgrp docker

sudo -H -u builder git config --global user.name "Resin Builder"
sudo -H -u builder git config --global user.email "buildy@builder.com"
echo "[INFO] The configured git credentials for user builder are:"
sudo -H -u builder git config --get user.name
sudo -H -u builder git config --get user.email

sudo -H -u builder "/compare_kernel_certs.sh" "$@" &

compare_kernel_certs_pid=$!
wait $compare_kernel_certs_pid || true

exit 0
