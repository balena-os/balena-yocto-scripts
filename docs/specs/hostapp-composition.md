# Hostapp Composition Build Pipeline

The `yocto-build-deploy` workflow builds a balenaOS hostapp release from a
Docker Compose composition declared by the device repo. The composition
specifies the hostapp service and any extension services (kernel modules,
firmware, drivers) the device type needs. Services with build metadata are built
in parallel via a matrix; build outputs and pre-existing registry images are
then assembled into a single release at deploy time.

## Composition files

The workflow reads a composition file at `${MACHINE}.hostapp.yml` in the device
repo root. When a meta-balena base composition exists at
`layers/meta-balena/hostapp.yml`, the workflow deep-merges the two with overlay
precedence. The merged result is the source of truth for both the build matrix
and the deployed composition.

Repos that build multiple device types provide per-device overlays
(`raspberrypi4-64.hostapp.yml`, `raspberrypi3-64.hostapp.yml`). If neither the
device overlay nor the meta-balena base exists for a machine, the workflow
generates a minimal default composition with a single hostapp service.

Composition files use Docker Compose v2.4 syntax. Build metadata is carried in
`x-*` extension fields, which compose parsers silently ignore.

## Service contract

Every service in the composition declares its build provenance and deploy
disposition. A valid service has **exactly one** of the following build
provenances:

- `x-build` block — the workflow builds the image via a Yocto recipe. The
  service's `image:` must be `__BUILD_OUTPUT__`.
- A concrete `image:` value (e.g., `ghcr.io/balena-os/journald-overlay:1.2.3`)
  and no `x-build` block — the image is pulled from a registry at deploy time.

The workflow validates this rule and fails fast on malformed services.

### Example

A meta-balena base composition declares the hostapp:

```yaml
# layers/meta-balena/hostapp.yml
version: "2.4"
services:
  hostapp:
    image: __BUILD_OUTPUT__
    x-build: {}
    labels:
      io.balena.image.store: "root"
      io.balena.image.class: "hostapp"
      io.balena.update.requires-reboot: "1"
      io.balena.private.hostapp.board-rev: "$DEVICE_REPO_REV"
```

A device overlay adds extensions:

```yaml
# balena-raspberrypi/raspberrypi4-64.hostapp.yml
version: "2.4"
services:
  kernel-modules:
    image: __BUILD_OUTPUT__
    x-build:
      recipe: balena-kernel-modules-block
      build_args:
        - -t
        - layers/meta-kernel-modules-block/conf/samples
```

The merged composition contains both services. The hostapp service builds with
no `-i` flag (falls back to the device type's `deploy_artifact`); kernel-modules
builds via `balena-kernel-modules-block`.

### `x-build` schema

| Field        | Type            | Required | Description                                                                                      |
| ------------ | --------------- | -------- | ------------------------------------------------------------------------------------------------ |
| `recipe`     | string          | no       | Bitbake image target. Omitted for hostapp (falls back to `deploy_artifact`); set for extensions. |
| `build_args` | list of strings | no       | Extra barys arguments specific to this service. Joined with spaces and appended to common args.  |
| `assets`     | list of strings | no       | File paths to upload as web resources attached to the balenaCloud release.                       |

### Opt-out signals

A device overlay opts out of base-composition services by setting keys to null
(`~`). yq's deep-merge operator propagates the null through the merge; the
prepare step then deletes the null entries. The mechanism is consistent at any
scope:

- **Remove a service entirely** — null the whole service key in the device
  overlay:

  ```yaml
  # device overlay
  services:
    kernel-modules: ~
  ```

  The merged composition has `kernel-modules: ~`, which the prepare step deletes
  before the build matrix and deploy.

- **Replace a built image with a registry image** — null only the `x-build`
  block and provide a concrete `image:`:

  ```yaml
  # device overlay
  services:
    kernel-modules:
      image: ghcr.io/balena-os/kernel-modules:1.0
      x-build: ~
  ```

  The service remains in the deployed composition but is no longer in the build
  matrix. Without a concrete `image:`, this combination fails the composition
  validation.

## Image field substitution

Built services declare `image: __BUILD_OUTPUT__` as a sentinel. The workflow
overwrites the sentinel at deploy time with the image reference returned by
`docker load`. Services with concrete `image:` values are passed through
unchanged.

After substitution, the workflow validates that no `__BUILD_OUTPUT__`
placeholders remain. A surviving placeholder means an extension archive failed
to match a service; the deploy fails fast.

## Image labels

Image labels carry two kinds of information:

1. **Structural labels** that drive supervisor and host runtime behavior —
   `io.balena.image.class`, `io.balena.image.store`,
   `io.balena.update.requires-reboot`.
2. **Compatibility labels** that constrain which devices may load an extension —
   `io.balena.image.kernel-version`, `io.balena.image.kernel-abi-id`.

How labels reach the image is the recipe's choice — `docker import --change`, a
`LABEL` directive in a Dockerfile, or a `labels:` block in the composition
(which `balena deploy` propagates onto the image at deploy time). The pipeline
is agnostic to the mechanism; it only requires the produced image carries the
labels its consumers expect. The composition is the right place for labels that
need workflow-time substitution (e.g.,
`io.balena.private.hostapp.board-rev: '$DEVICE_REPO_REV'`).

See [Image Labels Reference](../reference/image-labels.md) for the full catalog
and consumer table.

## Profiles

Services may use the compose `profiles` field for selective activation. The
pipeline treats `profiles` as pass-through: matrix parse, build, and deploy do
not interpret profile values. The default-generated composition does not set
`profiles`. Compose-parser support for `profiles` at deploy time is handled by a
runtime patch when the deployed composition uses them.

## Constraints

- All builds use Yocto. Non-Yocto build backends are not supported.
- Each device type builds its own extensions; no cross-device-type module
  sharing.
- Extensions produce a `.docker` archive named `${recipe}-${MACHINE}.docker`.
  The deploy step matches this filename to the service's `x-build.recipe` when
  substituting `__BUILD_OUTPUT__`.
