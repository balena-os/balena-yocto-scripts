# Hostapp Release Assets Contract

This document defines the release assets that must be attached to a finalized
balenaOS hostapp release for it to be considered valid and buildable by
image-maker and the OS download endpoints.

The `yocto-build-deploy` workflow uploads these assets to the draft release, and
the `Verify required release assets` step enforces this contract before the
release is finalized. A finalized release missing a required asset is not
buildable, so the workflow fails rather than publish it.

Assets are identified by their release `asset_key`, which mirrors the file's
path relative to the deploy directory (e.g. `compressed/part-0.deflate`,
`image.json`).

## Required

These assets MUST be present for a release to be valid and buildable:

```text
VERSION
VERSION_HOSTOS
device-type.json
image.json
compressed/.*
compressed-flasher/.*   # only when the device type declares a flasher artifact
compressed-raw/.*        # only when the device type declares a raw artifact
image-flasher.json       # only when the device type declares a flasher artifact
image-raw.json           # only when the device type declares a raw artifact
```

`VERSION`, `VERSION_HOSTOS` and `device-type.json` are produced for every device
type. `image.json` and the `compressed/` deflates exist for standard
compressible images; `edge`, `docker-image` and `archive`-type device types do
not produce them and are exempt.

A release can contain none, one, or both of the flasher/raw variants. Whenever
a variant's image is present, its `compressed-*/` deflates must be present and
must match the parts declared in the corresponding `image-*.json` manifest.

## Optional

These assets may be present but are not required:

```text
CHANGELOG.md
cyclonedx/.*
*.manifest
licenses.tar.gz
kernel_modules_headers.tar.gz
kernel_source.tar.gz
secure-boot-lock.tar.gz
```
