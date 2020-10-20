#!/bin/bash
set -e

source /manage-docker.sh

trap 'cleanup fail' SIGINT SIGTERM

# Create the normal user to be used for bitbake (barys)
echo "[INFO] Creating and setting builder user $BUILDER_UID:$BUILDER_GID."
groupadd -g $BUILDER_GID builder
groupadd docker
useradd -m -u $BUILDER_UID -g $BUILDER_GID -G docker builder

# Make the "builder" user inherit the $SSH_AUTH_SOCK variable set-up so he can use the host ssh keys for various operations
# (like being able to clone private git repos from within bitbake using the ssh protocol)
echo 'Defaults env_keep += "SSH_AUTH_SOCK"' > /etc/sudoers.d/ssh-auth-sock

# Disable host authenticity check when accessing git repos using the ssh protocol
# (not disabling it will make this script fail because /home/builder/.ssh/known_hosts file is empty)
mkdir -p /home/builder/.ssh/
echo "StrictHostKeyChecking no" > /home/builder/.ssh/config

# Start docker
echo "[INFO] Starting docker."
docker daemon 2> /dev/null &
wait_docker

# Authenticate with Balena registry if required
BALENAOS_ACCOUNT="balena_os"
BALENAOS_TOKEN=${BALENAOS_PRODUCTION_TOKEN}
if [ "$DEPLOY_TO" = "staging" ]; then
	BALENAOS_TOKEN=${BALENAOS_STAGING_TOKEN}
	export BALENARC_BALENA_URL=balena-staging.com
fi
if [ -n "${BALENAOS_TOKEN}" ]; then
	echo "[INFO] Logging into $DEPLOY_TO as ${BALENAOS_ACCOUNT}"
	balena login --token ${BALENAOS_TOKEN}
fi

sudo -H -u builder git config --global user.name "Resin Builder"
sudo -H -u builder git config --global user.email "buildy@builder.com"
echo "[INFO] The configured git credentials for user builder are:"
sudo -H -u builder git config --get user.name
sudo -H -u builder git config --get user.email

# Start barys with all the arguments requested
echo "[INFO] Running build as builder user..."
if [ -d /yocto/resin-board/balena-yocto-scripts ]; then
    sudo -H -u builder /yocto/resin-board/balena-yocto-scripts/build/barys $@ &
else
    sudo -H -u builder /yocto/resin-board/resin-yocto-scripts/build/barys $@ &
fi
barys_pid=$!
wait $barys_pid || true

cleanup
exit 0
