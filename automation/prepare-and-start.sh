#!/bin/bash

set -e

DOCKER_TIMEOUT=20 # Wait 20 seconds for docker to start

cleanup() {
    echo "[INFO] Running cleanup..."

    # Stop docker gracefully
    echo "[INFO] Stopping in container docker..."
    DOCKERPIDFILE=/var/run/docker.pid
    if [ -f $DOCKERPIDFILE ] && [ -s $DOCKERPIDFILE ] && ps $(cat $DOCKERPIDFILE) | grep -q docker; then
        kill $(cat $DOCKERPIDFILE)
        # Now wait for it to die
        STARTTIME=$(date +%s)
        ENDTIME=$(date +%s)
        while [ -f $DOCKERPIDFILE ] && [ -s $DOCKERPIDFILE ] && ps $(cat $DOCKERPIDFILE) | grep -q docker; do
            if [ $(($ENDTIME - $STARTTIME)) -le $DOCKER_TIMEOUT ]; then
                sleep 1
                ENDTIME=$(date +%s)
            else
                echo "[ERROR] Timeout while waiting for in container docker to die."
                exit 1
            fi
        done
    else
        echo "[WARN] Can't stop docker container."
        echo "[WARN] Your host might have been left with unreleased resources (ex. loop devices)."
    fi

    if [ "$1" == "fail" ]; then
        exit 1
    fi
}
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
echo "[INFO] Waiting for docker to initialize..."
STARTTIME=$(date +%s)
ENDTIME=$(date +%s)
until docker info >/dev/null 2>&1; do
    if [ $(($ENDTIME - $STARTTIME)) -le $DOCKER_TIMEOUT ]; then
        sleep 1
        ENDTIME=$(date +%s)
    else
        echo "[ERROR] Timeout while waiting for docker to come up."
        exit 1
    fi
done
echo "[INFO] Docker was initialized."

# Start barys with all the arguments requested
echo "[INFO] Running build as builder user..."
sudo -H -u builder /yocto/resin-board/resin-yocto-scripts/build/barys $@ &
barys_pid=$!
wait $barys_pid || true

cleanup
exit 0
