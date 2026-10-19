# Bundled injection runtime (private MIP build)

These binaries are a private build of [MIP](https://github.com/LIJI32/MIP)
(loader, injectd, lsdinjector, inject), built from the source vendored in
`third_party/mip/`. They are committed so that installing Spaces Renamer needs
no compiler, no GNU binutils and no separate MIP install.

MIP is X11 licensed (Copyright 2017-2025 Lior Halphon). The licence text and
the attribution are kept in `third_party/mip/LICENSE` and
`third_party/mip/README.md`.

## What the private build changes

Upstream MIP installs itself into
`/Library/Apple/System/Library/Frameworks/mip` and owns the Mach service
`local.injectd`. The private build:

- installs into its own root, `/Library/SpacesRenamer/mip`;
- owns the Mach service `com.wiggly-sheets.spaces-renamer.injectd`;
- uses the LaunchDaemon labels `com.wiggly-sheets.spaces-renamer.injectd` and
  `com.wiggly-sheets.spaces-renamer.lsdinjector`;
- never creates the `~/Library/MIP` symlink, so a system MIP install keeps
  working untouched;
- chains onto an existing `launchservicesd` hook instead of stealing the slot,
  so a system MIP install and this runtime can run side by side.

A system MIP install keeps loading the user's own tweaks; this runtime loads
only `SpacesRenamer.mip.bundle` from its own `Bundles` directory.

## Files

| File | Role |
|---|---|
| `injectd` | XPC daemon that performs the injection |
| `loader.dylib` | loaded into the target app, enumerates `Bundles` and loads matching bundles |
| `lsdinjector.dylib` | hooks `launchservicesd` so checked-in apps receive the loader |
| `inject` | command line injector, used to hook `launchservicesd` |
| `spacesrenamer.injectd.plist` | LaunchDaemon template for `injectd` (`@MIP_ROOT@`, `@MIP_SERVICE_NAME@` are substituted at install time) |
| `spacesrenamer.lsdinjector.plist` | LaunchDaemon template for the one-shot `launchservicesd` hook |

## Rebuilding

The build needs GNU binutils for `gobjcopy`, which turns the injection payload
dylibs into raw blobs. It is not part of the Xcode toolchain:

```bash
brew install binutils
export PATH="$(brew --prefix binutils)/bin:$PATH"
make -C third_party/mip/MIP MIP_ROOT=/Library/SpacesRenamer/mip \
    MIP_SERVICE_NAME=com.wiggly-sheets.spaces-renamer.injectd
```

Then copy the artifacts into this directory (`injectd`, `loader.dylib`,
`lsdinjector.dylib`, `inject`) and rebuild the app. `make mip` does the same
thing from the repository root and fails with a clear message when
`gobjcopy` is missing.

Every binary here is a thin `arm64e` build: the loader is only ever injected
into Apple silicon hosts, so the `x86_64` slice the vendored build adds is
useless. `make mip` thins the loader with `lipo -thin arm64e` before copying
the artifacts, so a rebuild reproduces the committed `arm64e`-only set.
