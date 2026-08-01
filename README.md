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
- CLI tool (`sr`) for scripting and quick actions
- scdoc-generated `sr(1)` manual page
- Deeplink URL scheme (`spacesrenamer://`) for integration
- Config file (`~/.config/spacesrenamer/config.toml`) for external profile management
- Universal app binary (`arm64` + `x86_64`)
- Universal Dock bundle (`arm64e` + `x86_64`)
- Modern app icon and native template menu-bar icon

Manual names are stored per Space UUID. Switching profiles immediately republishes the active mapping to the legacy `spaces_renaming` plist key, so the existing Dock injector remains compatible without restarting Spaces Renamer.

## Usage

### Menu Bar

- **Left-click** the menu bar item to open the rename popover.
- **Right-click** the menu bar item to switch profiles, choose a naming mode, or open Settings.
- Choose the icon, Space name, or number-and-name display under Settings → General.
- Press **Control–Option–R** from any app to toggle the renamer. Change it under Settings → Hotkey.
- Edit names in the popover. Return commits the current field; closing the popover saves edited manual names.

### CLI Tool (`sr`)

The `sr` CLI tool is bundled inside the app. On launch, Spaces Renamer symlinks it to `~/.local/bin/sr`.

```bash
sr status                  # Show current state (profile, naming mode, spaces)
sr renamer                 # Open rename popover
sr settings                # Open settings window
sr profile switch <uuid>   # Activate profile by UUID
sr profile list            # List profiles
sr naming manual           # Set manual naming mode
sr naming applications     # Set apps-in-space mode (requires yabai)
sr naming yabaiLabels      # Set yabai labels mode (requires yabai)
sr space <uuid> name <n>   # Set a manual name for a Space
sr help                    # Print usage
man sr                     # Read the full manual page
```

If `sr` is not found:

```bash
# Check ~/.local/bin is in PATH
echo $PATH | grep .local/bin
# Or symlink manually:
ln -sf /Applications/SpacesRenamer.app/Contents/Resources/sr ~/.local/bin/sr
```

### Deeplinks (`spacesrenamer://`)

The CLI wraps `open "spacesrenamer://..."`. Deeplinks work from any URL opener (browser, Shortcuts, etc.).

| URL | Action |
| --- | ------ |
| `spacesrenamer://settings` | Open settings |
| `spacesrenamer://renamer` | Toggle rename popover |
| `spacesrenamer://profile/switch/<uuid>` | Switch active profile |
| `spacesrenamer://profile/list` | Write status JSON |
| `spacesrenamer://naming/manual` | Set manual mode |
| `spacesrenamer://naming/applications` | Set apps mode |
| `spacesrenamer://naming/yabaiLabels` | Set yabai labels mode |
| `spacesrenamer://space/<uuid>/name?name=<encoded>` | Set space name |
| `spacesrenamer://status` | Write status JSON to `/tmp/spaces-renamer-status-$UID.json` |

### Config File

Spaces Renamer watches `~/.config/spacesrenamer/config.toml` for external profile management. Changes are merged live — no restart needed.

```toml
[settings]
# naming_mode = "manual"           # manual, applications, or yabaiLabels
# show_menu_bar = true
# menu_bar_display = "icon"        # icon, spaceName, or spaceNumberAndName
# show_duplicate_apps = false
# hotkey_key = 15                  # keyCode (15 = R)
# hotkey_ctrl = true
# hotkey_opt = true
# hotkey_cmd = false
# hotkey_shift = false
# login_item = false
# active_profile_id = ""

[profiles.Work]
# uuid = "00000000-0000-0000-0000-000000000000"
# "space-uuid" = "Display Name"

[profiles.Home]
# uuid = "11111111-1111-1111-1111-111111111111"
# "other-space-uuid" = "Another Name"
```

Profiles are matched by `uuid` field if present, falling back to section name.

## Installation

### Download from GitHub Releases

1. Download `SpacesRenamer-v{VERSION}.dmg` from the [Releases](https://github.com/wiggly-sheets/spaces-renamer/releases) page.
2. Open the DMG and drag `SpacesRenamer.app` to the Applications folder.
3. macOS may block unsigned apps. Remove the quarantine attribute:

   ```bash
   xattr -dr com.apple.quarantine /Applications/SpacesRenamer.app
   ```

   Alternatively, right-click the app in Finder and select **Open** from the context menu, then click **Open** in the dialog. This registers an exception for future launches.

### Build from Source

Requires Xcode 15 or newer and macOS 13 or newer.

```bash
make universal
```

Build products:

```text
.build/DerivedData/Build/Products/Release/SpacesRenamer.app
.build/DerivedData/Build/Products/Release/spaces-renamer.bundle
```

`make universal` verifies the architectures with `lipo`. The build also uses
`scdoc` to generate and bundle `sr(1)`:

```bash
brew install scdoc
make man
```

| Artifact | Architectures |
| -------- | ------------- |
| `SpacesRenamer.app` | `arm64` `x86_64` |
| `spaces-renamer.bundle` | `arm64e` `x86_64` |
| `injection/lib/spaces-renamer.dylib` | `arm64e` |

## Injection

The repository's `injection/` folder contains the current `dylinject` workflow:

```bash
./injection/run.sh
```

The supplied injector is currently `arm64e`-only. The Xcode Dock-bundle target also emits an `x86_64` slice, but Intel injection needs a compatible Intel injector.

The injector workflow requires Apple silicon, the `-arm64e_preview_abi` boot argument, and either fully or partially disabled System Integrity Protection (SIP). These settings materially reduce macOS security. Review and understand the implications before changing them. Building the app does not run the injector, modify security settings, or restart Dock.

On first launch, the app asks whether to enable Dock renaming and offers Launch at Login as a recommended option. Keeping Dock renaming active lets the app detect a new Dock process after a Dock or computer restart, but every injection still shows the standard macOS administrator-authorization prompt. Cancelling that prompt suppresses further automatic requests for the same Dock process; use Settings → Injection → Inject Now to retry.

Set the required boot argument with:

```bash
sudo nvram boot-args="-arm64e_preview_abi"
```

`amfi_get_out_of_my_way=1` is not universally required. It is an optional troubleshooting measure for systems where the injector still cannot obtain the Dock task port. If you need it, preserve the required argument by setting both values in one command: `sudo nvram boot-args="-arm64e_preview_abi amfi_get_out_of_my_way=1"`.

From macOS Recovery, either disable SIP fully:

```bash
csrutil disable
```

or use the narrower configuration currently supported by this project:

```bash
csrutil enable --without fs --without debug --without nvram
```

Restart after changing these settings. Spaces Renamer checks both the required boot argument and SIP status; it never changes either setting for you.

### Profiling the Dock hook

The injected bundle emits `os_signpost` data under subsystem
`com.wiggly-sheets.spaces-renamer` and category `DockHook`. Attach Instruments
to Dock with the Points of Interest or Time Profiler instrument, then open and
close Mission Control. `ApplyNames` intervals report cache hits, whether layout
state changed, the number of Spaces processed, and how many label subtrees were
refreshed. `ReloadPlists` events identify cache invalidations.

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
