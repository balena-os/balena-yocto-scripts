Automation scripts for multi-container hostOS images 
====================================================

The architecture of BalenaOS envisions a modularized system composed of hostOS blocks which are built and maintained separately and come together on a multi-container hostOS image.

This document explains how the Jenkins build scripts have been extended to build and deploy both hostOS blocks and multi-container hostOS apps.

Building multi-container hostOS images
--------------------------------------

__jenkins_build-hostos__: This script is the entry point to build multi-container hostOS images.

  * __Inputs__:
    * __hostOSBlocks__: The optional name of the public Balena applications to fetch and optionally build/deploy the blocks. If not given only the core hostapp is included in the hostOS image.
    * __MACHINE__: The device type to build for.
  * __Outputs__: Target images with preloaded hostOS block images and other build artifacts

The script will:

* Build and deploy a hostOS block if required
* Fetch the specified hostOS block names at the current BalenaOS release version and preload them into the target image.
* Deploy a multi-container hostOS app

Building and deploying the hostOS block
---------------------------------------

HostOS blocks elementary units are container images, and as such they can be built from any source. Typically they are built from a package feed following a three steps approach:

* Building and deploying a package feed with the required packages
* Building and deploying the hostOS block image to Balena's registry
* Building a target image with the specified hostOS block images

The package feed is built and stored locally on the *deploy-jenkins* folder. The meta-data used to build the package feed from comes from the Balena contract which is part of the device repository. An [example contract](https://raw.githubusercontent.com/balena-os/balenaos-contracts/master/contracts/sw.image/tegra-gpu/contract.json).

The *balena-deploy-block.sh*  script will then use the local package feed to build the hostOS block from a pre-defined Dockerfile and deploy to the Balena registry creating a public application if needed.
