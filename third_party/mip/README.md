# third_party/mip — vendored MIP runtime (private build)

This directory contains a vendored copy of [MIP](https://github.com/LIJI32/MIP) (the macOS
Injection Platform by Lior Halphon), patched and built as a **private** injection runtime
that lives entirely under `/Library/SpacesRenamer/mip`.

It exists so that SpacesRenamer can ship its own injection stack inside
`SpacesRenamer.app` without touching (or depending on) a system-wide MIP installation.

## Provenance

| | |
|---|---|
| Upstream | https://github.com/LIJI32/MIP |
| Upstream commit vendored | `e944f7eb61df6b0af10e22b69290233bd6743bfd` (`master`, 2025-09-15, "Merge pull request #42 from zhkl0228/master") |
| Upstream license | MIT / X11 — see `LICENSE` (upstream `LICENSE`, unmodified) and `MIP/third-party/substitute/LICENSE.txt` (BSD, unmodified) |
| Vendored paths | `LICENSE`, `MIP/Makefile`, `MIP/libSystem.tbd`, `MIP/local.injectd.plist`, `MIP/local.lsdinjector.plist`, `MIP/injector/**`, `MIP/loader/**`, `MIP/third-party/substitute/**` |

Deliberately **not** vendored:

- `Bundles/Alt-Zoom/**` — upstream's sample tweak, not needed.
- `MIP/third-party/markgc.cpp` — legacy Objective-C garbage collector support, not referenced
  by the upstream `Makefile` and not built (GC was removed in macOS Sierra).

`MIP/local.injectd.plist` and `MIP/local.lsdinjector.plist` are kept unmodified for reference
and to make re-vendoring easy; the private runtime uses the plists described below.

## Patches applied to the vendored source

Every patch is listed here. The upstream tree can be re-derived with
`git diff` against upstream `e944f7e` (see "Reproducing the diff" below).

### 1. Private Mach service name

`MIP/injector/injectd_client/mip_service_name.h` (new) defines the service name:

```c
#define MIP_MACH_SERVICE_NAME "com.wiggly-sheets.spaces-renamer.injectd"
```

It replaces the hardcoded upstream name `local.injectd` in:

- `MIP/injector/injectd_client/injectd_client.m` — `initWithMachServiceName:@(MIP_MACH_SERVICE_NAME)`
  (this file is compiled into `lsdinjector.dylib` and into the `inject` CLI),
- `MIP/injector/injectd.m` — `initWithMachServiceName:@(MIP_MACH_SERVICE_NAME)` (the daemon that
  owns the service).

The private LaunchDaemon plist declares the same name in its `MachServices` key. The
`Makefile` substitutes it from `MIP_SERVICE_NAME` and fails the build if the two disagree, so
the daemon, the client and the plist can never drift apart.

Effect: the private chain talks to its **own** `injectd` over its **own** Mach service, so it
never queues behind, and never interferes with, a system MIP `injectd`.

### 2. No `~/Library/MIP` symlink

Upstream's `lsd_injector.c` creates a `~/Library/MIP` symlink pointing at
`<MIP_ROOT>/user_data/<uid>` for every user it injects into. The private build does **not**
create that symlink: the user may already have one that belongs to a system MIP install, and
replacing it would break that install.

The private runtime keeps its per-user data in its own root
(`/Library/SpacesRenamer/mip/user_data/<uid>`) and the loader reads it from there
(`MIP/loader/loader.m`, `MIP_user_data_path()`), which is derived from the loader's own
path — no symlink needed.

### 3. Coexistence with another lsdinjector in `launchservicesd`

Upstream's hook replaces the single `launchservicesd` GOT slot that points at
`xpc_dictionary_get_int64`. A **second** `lsdinjector` that is injected later looks for a
slot that still holds the original symbol, finds none, and silently never installs its hook:
that chain stops injecting anything.

`MIP/injector/lsd_injector.c` therefore:

- finds the slot either by the original symbol (nothing hooked yet) **or** by a pointer into
  another loaded `lsdinjector.dylib` image (another chain hooked it first), and
- chains onto the hook it found: the new hook calls the previous one, so both chains keep
  injecting, and
- when the slot is still untouched it waits up to 15 s for a competing chain to take it
  first (both LaunchDaemons race at boot) and only claims the slot itself if nobody else
  did. The wait runs on a detached thread, so `launchservicesd` is never blocked.

The saved "previous" function pointer is re-signed with `ptrauth_key_function_pointer` and
discriminator 0 before it is called, which is what clang's `braaz` (the indirect-call
sequence on arm64e) authenticates.

### 4. Private build rules (`MIP/Makefile`)

- `BUILD_DIR ?= build` — all build products go to `$(BUILD_DIR)`, so the vendored tree stays
  clean. Use `BUILD_DIR=<repo>/.build/mip` to keep them out of the tree entirely.
- `MIP_ROOT ?= /Library/SpacesRenamer/mip` (upstream default was the system MIP root).
- `MIP_SERVICE_NAME`, `MIP_INJECTD_LABEL`, `MIP_LSDINJECTOR_LABEL` — the private identity.
- `GOBJCOPY ?= gobjcopy` — GNU binutils' `gobjcopy` is not part of the Xcode toolchain
  (`brew install binutils`).
- The upstream `install` and `uninstall` targets are **disabled** (`make install` now fails
  with an explanation). They would overwrite a system MIP install
  (`/Library/Apple/System/Library/Frameworks/mip`, `/usr/local/bin/inject`).
- New target `private-install`, which calls `MIP/install-private.sh`.

### 5. Private LaunchDaemons (new plists)

`MIP/spacesrenamer.injectd.plist` and `MIP/spacesrenamer.lsdinjector.plist` mirror the
upstream plists, with `@MIP_ROOT@` / `@MIP_SERVICE_NAME@` placeholders substituted at build
time:

| | upstream | private |
|---|---|---|
| injectd label | `local.injectd` | `com.wiggly-sheets.spaces-renamer.injectd` |
| injectd Mach service | `local.injectd` | `com.wiggly-sheets.spaces-renamer.injectd` |
| lsdinjector label | `local.lsdinjector` | `com.wiggly-sheets.spaces-renamer.lsdinjector` |
| lsdinjector program | `/usr/local/bin/inject launchservicesd <MIP_ROOT>/lsdinjector.dylib -w4` | `<MIP_ROOT>/inject launchservicesd <MIP_ROOT>/lsdinjector.dylib -w4` |

`RunAtLoad`, `KeepAlive`/`SuccessfulExit=false`, `GroupName`, `UserName` and
`ThrottleInterval` are identical to upstream.

### 6. Private installer (new `MIP/install-private.sh`)

Installs the runtime into `<MIP_ROOT>` (root:wheel, 0755), copies the `inject` CLI next to
it (`<MIP_ROOT>/inject`, **not** `/usr/local/bin/inject`), installs the two LaunchDaemon
plists, and bootstraps them.

It never writes to a system MIP install, to `/usr/local/bin`, to `/usr/local/include` or to a
user's `~/Library/MIP`.

It only writes `DisableLibraryValidation` in
`/Library/Preferences/com.apple.security.libraryvalidation.plist` when that key is missing
(Apple-signed processes refuse to load libraries that are not signed by Apple; a system MIP
install usually already disabled it).

## Layout of the private runtime

```text
/Library/SpacesRenamer/mip/
├── inject                     # private CLI (upstream's `inject`)
├── injectd                    # private Mach service daemon
├── loader.dylib               # universal (arm64e + x86_64)
├── lsdinjector.dylib          # arm64e, hooks launchservicesd
├── user_data/<uid>/           # per-user settings (no ~/Library/MIP symlink)
└── Bundles/
    └── SpacesRenamer.mip.bundle
        └── Contents/MacOS/SpacesRenamer
```

The runtime is **relocatable**: `lsdinjector.dylib` and `loader.dylib` derive their root
from their own loaded path (`dladdr`), so the same binaries work from any root. The private
root only appears in the LaunchDaemon plists.

## Build

```bash
cd third_party/mip/MIP
make BUILD_DIR="$PWD/../../../.build/mip" \
     GOBJCOPY="$(brew --prefix)/opt/binutils/bin/gobjcopy" \
     SIGN_IDENTITY=- \
     all
```

`SIGN_IDENTITY=-` ad-hoc signs the binaries, like upstream's `CodeSign` identity does for a
self-signed certificate. `gobjcopy` is a build-time-only dependency (GNU binutils).

## Install (root)

```bash
# macOS: run through the standard admin prompt
osascript -e "do shell script \"/bin/bash '$PWD/install-private.sh' /Library/SpacesRenamer/mip '$PWD/../../../.build/mip' com.wiggly-sheets.spaces-renamer.injectd com.wiggly-sheets.spaces-renamer.lsdinjector\" with administrator privileges"
```

## Reproducing the diff

```bash
git clone https://github.com/LIJI32/MIP.git /tmp/MIP && git -C /tmp/MIP checkout e944f7e
diff -ru /tmp/MIP/MIP/injector third_party/mip/MIP/injector
diff -ru /tmp/MIP/MIP/loader third_party/mip/MIP/loader
diff -u  /tmp/MIP/MIP/Makefile third_party/mip/MIP/Makefile
```

## Known limits

- The private runtime is **not** a supported upstream configuration: it is a patched build of
  a third-party project. It has to be rebuilt when upstream changes.
- `MIP/loader/loader.m` is upstream's, unmodified: it loads every bundle in
  `<MIP_ROOT>/Bundles` whose `Info.plist` filter matches the host process.
- The private `injectd` and the system `injectd` both run as root and both use
  `task_for_pid`; they are independent services and do not share state.
