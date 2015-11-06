# Resin.io core repository

## Clone/Initialize the repository

There are two ways of initializing this repository:
* Clone this repository with "git clone --recurse-submodules".

or

* Run "git submodules init" and then "git submodule sync --recursive". This will bring in all the needed dependencies.

## Manual resin build for a specific machine
* Change directory in the desired resin-bsp-<target> directory.
* Run "export TEMPLATECONF=../meta-resin-<target>/conf/samples/".
* Run "source ./resin-init-build-env".
* Run the appropriate bitbake command.
