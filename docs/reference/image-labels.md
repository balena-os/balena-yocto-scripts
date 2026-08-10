# Image Labels

Catalog of `io.balena.*` image labels consumed across balenaOS components — the
supervisor, mobynit, and extension-runtime.

Labels reach images by whichever mechanism the recipe chooses —
`docker import --change`, a Dockerfile `LABEL` directive, or a `labels:` block
in the composition (which `balena deploy` propagates at deploy time). Some are
set at runtime by the supervisor. This catalog lives in `balena-yocto-scripts`
because the build pipeline is positioned between the producers (extension and
hostapp recipes, cross-repo) and the runtime consumers (supervisor, mobynit,
extension-runtime, also cross-repo) — updates should be coordinated when label
semantics change.

## `io.balena.image.*` labels

| Label                            | Consumed by                                                    | Set by                                              | Purpose                                                                              |
| -------------------------------- | -------------------------------------------------------------- | --------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `io.balena.image.class`          | mobynit, extension-runtime, supervisor                         | Yocto recipe / image Dockerfile                     | Identifies image role. Accepted values: `hostapp`, `overlay`.                        |
| `io.balena.image.override`       | mobynit                                                        | Image Dockerfile                                    | Numeric priority `N` — mounts extension left of hostapp in lowerdir.                 |
| `io.balena.image.kernel-version` | mobynit, extension-runtime (cleanup)                           | Yocto recipe                                        | Coarse userspace kernel ABI (`M.m.p`) for module and userspace compatibility checks. |
| `io.balena.image.kernel-abi-id`  | mobynit (`FilterByKernelABIID`), extension-runtime (cleanup)   | Yocto recipe (sha256 of the kernel image)           | Precise kernel-ABI fingerprint for kernel-module and BTF/eBPF compatibility checks.  |
| `io.balena.image.store`          | supervisor (`extensions.ts:32-33, 264`)                        | Supervisor default `data`, or compose labels        | Where to materialise the extension (`data` vs `root`).                               |
| `io.balena.image.os-version`     | (no consumer yet)                                              | Yocto recipe (`${HOSTOS_VERSION}`)                  | OS version pin. Stamped onto extension images for future use and debugging.          |

### Deprecated

| Label                             | Replacement                        |
| --------------------------------- | ---------------------------------- |
| `io.balena.image.requires-reboot` | `io.balena.update.requires-reboot` |

## `io.balena.*` labels (supervisor-wide)

| Label                                                                                                 | Consumed by                                    | Purpose                                  |
| ----------------------------------------------------------------------------------------------------- | ---------------------------------------------- | ---------------------------------------- |
| `io.balena.supervised`                                                                                | supervisor                                     | Marks supervisor-managed containers.     |
| `io.balena.app-id`, `io.balena.app-uuid`, `io.balena.service-id`, `io.balena.service-name`            | supervisor                                     | Service identity metadata.               |
| `io.balena.legacy-container`                                                                          | supervisor (`lib/legacy.ts`, `compose/app.ts`) | Legacy single-container migration state. |
| `io.balena.update.strategy`, `io.balena.update.handover-timeout`, `io.balena.update.requires-reboot`  | supervisor                                     | Update and rollout strategy flags.       |
| `io.balena.features.supervisor-api`, `io.balena.features.optional`, `io.balena.features.journal-logs` | supervisor                                     | Per-service feature opt-ins.             |

## `io.balena.private.*` labels

| Label                                 | Consumed by         | Purpose                                                                                             |
| ------------------------------------- | ------------------- | --------------------------------------------------------------------------------------------------- |
| `io.balena.private.hostapp.board-rev` | supervisor (helios) | Board revision identification used by [helios](https://github.com/balena-io/helios) for OS updates. |

## Kernel ABI compatibility

Two of the labels above gate whether an extension may load on a given device:

- `io.balena.image.kernel-version` (`M.m.p`) covers userspace / syscall / sysfs
  compatibility. Sufficient for extensions that only use userspace interfaces.
- `io.balena.image.kernel-abi-id` is the sha256 of the kernel image. It changes
  whenever the kernel binary changes, so it catches both modversions-level
  incompatibilities for kernel modules and BTF-level incompatibilities for eBPF
  programs. It replaced a hash of `Module.symvers`: that value covers modules,
  but two rebuilds of the same kernel config can share a `Module.symvers` while
  carrying incompatible vmlinux/module BTF, so it can't disambiguate them. The
  kernel-image hash covers every case. Required for extensions that load kernel
  modules or use eBPF.

Both labels are stamped at Yocto build time. At runtime the booted kernel's
identity comes from the `balena_kernel_abi` token on `/proc/cmdline`, published
by the initrd and carrying the sha256 of the kexec'd kernel image; when the
token is absent (a stock, non-kexec boot) there is no running abi-id, so any
extension that claims a `kernel-abi-id` fails the match. The
[supervisor](https://github.com/balena-os/balena-supervisor) and
[balena-extension-runtime](https://github.com/balena-os/balena-extension-runtime)
consume the labels during extension lifecycle management; mobynit applies them
at overlay mount time.

## References

- [`automation/include/balena-api.inc`](https://github.com/balena-os/balena-yocto-scripts/blob/master/automation/include/balena-api.inc)
  — label query helpers (reads labels from deployed releases via the balenaCloud
  API)
- [`balena-supervisor/src/compose/app.ts`](https://github.com/balena-os/balena-supervisor/blob/master/src/compose/app.ts)
  — supervisor compose handling
- [`balena-extension-runtime`](https://github.com/balena-os/balena-extension-runtime)
  — extension lifecycle component (under development)
- [mobynit#25](https://github.com/balena-os/mobynit/pull/25) — switches
  `kernel-abi-id` from a `Module.symvers` hash to the kernel-image sha256 (BTF
  disambiguation)
- [balena-extension-runtime#6](https://github.com/balena-os/balena-extension-runtime/pull/6)
  — reads the running kernel's abi-id from the `balena_kernel_abi` cmdline token
