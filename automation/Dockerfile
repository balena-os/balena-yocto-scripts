FROM ubuntu:15.04

# Install the following utilities (required by poky)
RUN apt-get update && apt-get install -y build-essential chrpath curl diffstat gcc-multilib gawk git-core libsdl1.2-dev texinfo unzip wget xterm cpio file && rm -rf /var/lib/apt/lists/*

# Additional host packages required by resin
RUN apt-get update && apt-get install -y jq npm nodejs sudo && rm -rf /var/lib/apt/lists/*

# Fix path of node/nodejs
RUN ln -s /usr/bin/nodejs /usr/bin/node

# Install docker
# https://github.com/docker/docker/blob/master/project/PACKAGERS.md#runtime-dependencies
RUN apt-get update && apt-get install -y iptables procps e2fsprogs xfsprogs xz-utils git kmod && rm -rf /var/lib/apt/lists/*
ENV DOCKER_VERSION 1.10.1
VOLUME /var/lib/docker
RUN wget -q -O /usr/bin/docker https://get.docker.com/builds/Linux/x86_64/docker-${DOCKER_VERSION} && chmod +x /usr/bin/docker

COPY prepare-and-start.sh /

WORKDIR /yocto/resin-board
