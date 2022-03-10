#!/bin/bash

set -ex

# TODO: determine this stuff automatically from the environment
MACHINE="genericx86-64"
SRC_URI="git://git.yoctoproject.org/linux-yocto.git"
KBRANCH="v5.10/standard/base"
SRCREV="$(git ls-remote --sort="v:refname" -q ${SRC_URI} ${KBRANCH} | awk '{print $1}')"
RECIPE="layers/meta-balena-genericx86/recipes-kernel/linux/linux-yocto_5.10.bbappend"

trap 'rm -rf ${tmpdir}' EXIT
tmpdir="$(mktemp -d)"

# TODO: find a way to get the latest tag merged to this branch without cloning
git clone --depth 1 "${SRC_URI}" -b "${KBRANCH}" "${tmpdir}"
git rev-parse --abbrev-ref HEAD

LINUX_VERSION="5.10.$(grep '^SUBLEVEL =' "${tmpdir}"/Makefile | awk '{print $3}')"

sed -e "s/LINUX_VERSION_${MACHINE} = .*/LINUX_VERSION_${MACHINE} = \"${LINUX_VERSION}\"/" \
    -e "s/SRCREV_machine_${MACHINE} ?= .*/SRCREV_machine_${MACHINE} = \"${SRCREV}\"/" \
    -i "${RECIPE}"
