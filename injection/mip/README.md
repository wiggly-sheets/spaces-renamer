# Bundled injection loader (private MIP build)

`loader.dylib` is a private build of [MIP](https://github.com/LIJI32/MIP),
built from the source vendored in `third_party/mip/`. It is committed so that
installing Spaces Renamer needs no compiler, no GNU binutils and no separate
MIP install.

MIP is X11 licensed (Copyright 2017-2025 Lior Halphon). The licence text and
the attribution are kept in `third_party/mip/LICENSE` and
`third_party/mip/README.md`.

## How it loads

The app installs the loader and `SpacesRenamer.mip.bundle` into
`~/Library/Application Support/SpacesRenamer/mip`. Activation sets
`DYLD_INSERT_LIBRARIES` to the loader for one host restart, then removes it.
The loader reads `Bundles` from its own directory and maps the bundle only
into the executables named in the bundle's `Info.plist`
(`WindowManager` on macOS 27+, `Dock` earlier).

This path needs no root install, no LaunchDaemon, no Mach service and no AMFI
boot argument. The old `injectd` / `lsdinjector` daemon chain is not shipped:
on macOS 27 launchd rejects it unless `amfi_get_out_of_my_way` is set.

## Rebuilding

The build needs GNU binutils for `gobjcopy`, which turns the injection payload
dylibs into raw blobs. It is not part of the Xcode toolchain:

```bash
brew install binutils
make mip
```

`make mip` finds `gobjcopy` in the Homebrew keg, so no `PATH` export is
needed. It copies the rebuilt loader into this directory and thins it to
`arm64e`; the committed artifact stays authoritative, so restore it with
`git checkout -- injection/mip/` unless a rebuild is intended.

The loader is signed ad-hoc by default. Pass a real identity to sign it
properly:

```bash
make mip SIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
```

The loader is a thin `arm64e` build: it is only ever injected into Apple
silicon hosts.
