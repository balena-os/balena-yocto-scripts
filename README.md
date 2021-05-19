# Yocto tools for using with Balena

This repository provides helper scripts and tools for building Balena OS.

* __build/barys__: Used for native builds, barys is a wrapper script over bitbake that builds BalenaOS. Used to initialize a build directory and create device type json files out of the coffeescript files, and then run the default build. Use `-n` to just setup the build directory.
* __build/balena-build.sh__: Used to build in a container, this script downloads a container builder image and calls barys.
* __automation/jenkins_build.sh__: Used in jenkins automation to build the OS, requires a jenkins environment to work.
* __automation/jenkins_build-blocks.sh__: Used in jenkins automation to build OS blocks defined in a hostOS contract, requires a jenkins environment to work.

## Contributing

### Issues

For issues we use an aggregated github repository available [here](https://github.com/balena-os/balena-os/issues). When you create issue make sure you select the right labels.

### Pull requests

To contribute send github pull requests targeting this repository.

Please refer to: [Yocto Contribution Guidelines](https://wiki.yoctoproject.org/wiki/Contribution_Guidelines#General_Information) and try to use the commit log format as stated there. Example:
```
test.bb: I added a test

[Issue #01]

I'm going to explain here what my commit does in a way that history
would be useful.

Signed-off-by: Joe Developer <joe.developer@example.com>
```

Make sure you mention the issue addressed by a PR. See:
* https://help.github.com/articles/autolinked-references-and-urls/#issues-and-pull-requests
* https://help.github.com/articles/closing-issues-via-commit-messages/#closing-an-issue-in-a-different-repository
