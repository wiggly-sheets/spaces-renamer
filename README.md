# Spaces Renamer

Spaces Renamer gives macOS Spaces persistent, useful names in Mission Control. The menu-bar app is built with SwiftUI; the injected Dock bundle retains the existing Objective-C runtime integration.

## Features

- SwiftUI renamer popover and settings window
- Work and Home profiles by default, with custom profiles
- Instant profile switching from the menu bar
- Configurable global hotkey (default: Control–Option–R)
- Three naming modes: manual profiles, apps occupying each Space, or live yabai Space labels
- Optional per-window app names, allowing repeated names such as `Safari · Safari`
- Menu bar display choices: app icon, current Space name, or number and name
- Native macOS launch-at-login support
- Native prompt to move the app into `/Applications`
- Universal app binary (`arm64` + `x86_64`)
- Universal Dock bundle (`arm64e` + `x86_64`)
- Modern app icon and native template menu-bar icon

Manual names are stored per Space UUID. Switching profiles immediately republishes the active mapping to the legacy `spaces_renaming` plist key, so the existing Dock injector remains compatible without restarting Spaces Renamer.

## Build

Requires Xcode 15 or newer and macOS 13 or newer.

```bash
make universal
```

Build products:

```text
.build/DerivedData/Build/Products/Release/SpacesRenamer.app
.build/DerivedData/Build/Products/Release/spaces-renamer.bundle
```

`make universal` verifies the architectures with `lipo`.

## Injection

The repository’s `injection/` folder contains the current `dylinject` workflow:

```bash
./injection/run.sh
```

The supplied injector is currently `arm64e`-only. The Xcode Dock-bundle target also emits an `x86_64` slice, but Intel injection needs a compatible Intel injector.

The injector workflow requires reduced macOS security protections. Review the script and understand the SIP/AMFI implications before running it. Building the app does not run the injector or restart Dock.

### Profiling the Dock hook

The injected bundle emits `os_signpost` data under subsystem
`com.wiggly-sheets.spaces-renamer` and category `DockHook`. Attach Instruments
to Dock with the Points of Interest or Time Profiler instrument, then open and
close Mission Control. `ApplyNames` intervals report cache hits, whether layout
state changed, the number of Spaces processed, and how many label subtrees were
refreshed. `ReloadPlists` events identify cache invalidations.

## Usage

- Left-click the menu bar item to open the renamer.
- Right-click the menu bar item to switch profiles, choose a naming mode, or open Settings.
- Choose the icon, Space name, or number-and-name display under Settings → General.
- Press Control–Option–R from any app to toggle the renamer. Change it under Settings → Hotkey.
- Edit names in the popover. Return commits the current field; closing the popover saves edited manual names.

## Data

Modern settings:

```text
~/Library/Application Support/SpacesRenamer/preferences.json
```

Dock compatibility files:

```text
~/Library/Containers/com.alexbeals.spacesrenamer/com.alexbeals.spacesrenamer.plist
~/Library/Containers/com.alexbeals.spacesrenamer/com.alexbeals.spacesrenamer.currentspaces.plist
```

Existing names are migrated into the Work profile on first launch.

## Caveats

Spaces Renamer relies on private macOS APIs and Dock injection. macOS updates may require changes to the injected bundle. Both dynamic naming modes require yabai. App-based naming includes standard, user-facing accessibility windows and intentionally omits background or placeholder records.
