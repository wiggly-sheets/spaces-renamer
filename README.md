<div align="center">

  <img src="SpacesRenamer/Assets.xcassets/AppIcon.appiconset/app-icon-512.png" width="128" alt="Spaces Renamer app icon" />

  <h1>Spaces Renamer</h1>

  <p><b>Give every macOS Space a name that sticks.</b></p>

  <p>
    Name Spaces from a small native menu-bar app and see those names in Mission Control.<br />
    Manual profiles, application-based labels, and yabai labels—without giving up your workflow.
  </p>

  <p>
    <a href="https://github.com/wiggly-sheets/spaces-renamer/actions/workflows/release.yml"><img src="https://img.shields.io/github/actions/workflow/status/wiggly-sheets/spaces-renamer/release.yml?label=release" alt="Release workflow status" /></a>
    <a href="https://github.com/wiggly-sheets/spaces-renamer/releases"><img src="https://img.shields.io/github/v/release/wiggly-sheets/spaces-renamer?label=latest" alt="Latest release" /></a>
    <a href="LICENSE"><img src="https://img.shields.io/github/license/wiggly-sheets/spaces-renamer" alt="License" /></a>
    <img src="https://img.shields.io/badge/macOS-13%2B-000000?logo=apple" alt="macOS 13 or later" />
  </p>

  <p>
    <a href="https://github.com/wiggly-sheets/spaces-renamer/releases/latest"><b>Download</b></a>
    &nbsp;·&nbsp;
    <a href="#installation">Install guide</a>
    &nbsp;·&nbsp;
    <a href="#using-spaces-renamer">Usage</a>
    &nbsp;·&nbsp;
    <a href="#building-from-source">Build from source</a>
    &nbsp;·&nbsp;
    <a href="#security-and-compatibility">Security</a>
  </p>

</div>

---

macOS does not give Spaces persistent names. Spaces Renamer does: choose names yourself, organize them into profiles such as **Work** and **Home**, or generate labels from the apps in each Space or from yabai.

It is a native macOS menu-bar app paired with a small bundle that teaches Mission Control to display the names. Profile and name changes are published immediately—there is no need to restart the app or Dock.

> [!WARNING]
> Showing names inside Mission Control requires injecting the Dock bundle. This currently needs Apple silicon and reduced macOS security protections. Read [Security and compatibility](#security-and-compatibility) before enabling it.

## Features

- Native SwiftUI menu-bar popover and settings window
- Persistent manual names, keyed by each macOS Space UUID
- Built-in **Work** and **Home** profiles, plus your own profiles
- Switch profiles instantly from the menu bar
- Three naming modes: **Manual Profiles**, **Apps in Space**, and **yabai Space Labels**
- Apps mode can show up to three real, user-facing apps in reading order; optionally retain duplicates such as `Safari · Safari`
- Menu-bar display: icon, current Space name, or number and name
- Configurable global hotkey (Control–Option–R by default)
- Launch at login, a bundled `sr` command-line tool, deeplinks, and a live TOML config file
- Universal app (`arm64` + `x86_64`) and Dock bundle (`arm64e` + `x86_64`)

Generated naming modes require [yabai](https://github.com/koekeishiya/yabai). Apps mode deliberately filters out background, minimized, hidden, zero-sized, and placeholder windows so labels reflect the apps you are actually using.

---

## Installation

### Download the app

1. Download `SpacesRenamer-v{VERSION}.dmg` from [GitHub Releases](https://github.com/wiggly-sheets/spaces-renamer/releases/latest).
2. Open the DMG and drag **SpacesRenamer.app** to **Applications**.
3. Open the app. If macOS blocks the unsigned build, right-click it in Finder, choose **Open**, then confirm **Open**. Alternatively:

   ```bash
   xattr -dr com.apple.quarantine /Applications/SpacesRenamer.app
   ```

The app runs on macOS 13 or later. Naming Spaces in Mission Control is optional; you can configure profiles and names before enabling Dock injection.

### Enable Mission Control names

On first launch, Spaces Renamer can guide you through enabling Dock renaming. The current injector needs:

- Apple silicon
- the `-arm64e_preview_abi` boot argument
- SIP either disabled or configured with the supported narrower exceptions
- administrator authorization to inject into the current Dock process

The app checks these prerequisites but never changes security settings, modifies boot arguments, or restarts Dock itself. You can retry from **Settings → Injection → Inject Now** at any time.

---

## Using Spaces Renamer

### Menu bar

- **Left-click** the status item to rename Spaces.
- **Right-click** it to switch profiles, choose a naming mode, or open Settings.
- Choose icon, Space name, or number-and-name display in **Settings → General**.
- Press **Control–Option–R** from anywhere to toggle the renamer; change this in **Settings → Hotkey**.
- Press Return to commit the active name. Closing the popover also saves edited manual names.

### Profiles and naming modes

Manual names belong to profiles, so one set of Spaces can be **Work** during the week and **Home** after hours. Names are stored against stable Space UUIDs and the active profile is republished to Dock immediately when it changes.

| Mode | What appears in Mission Control | Requires yabai |
| --- | --- | --- |
| Manual Profiles | The names you assign to each Space | No |
| Apps in Space | Up to three app names, e.g. `Xcode · Safari` | Yes |
| yabai Space Labels | Labels defined in yabai | Yes |

### Command line (`sr`)

Spaces Renamer installs a convenient `sr` symlink at `~/.local/bin/sr` on launch.

```bash
sr status                  # Profile, naming mode, and spaces
sr renamer                 # Open the rename popover
sr settings                # Open Settings
sr profile list            # List profiles
sr profile switch <uuid>   # Activate a profile
sr naming manual           # Use manual names
sr naming applications     # Name Spaces from apps (needs yabai)
sr naming yabaiLabels      # Use yabai Space labels
sr space <uuid> name <n>   # Set a manual name
man sr                     # Read the full manual
```

If the command is unavailable, make sure `~/.local/bin` is in your `PATH`, or create it yourself:

```bash
ln -sf /Applications/SpacesRenamer.app/Contents/Resources/sr ~/.local/bin/sr
```

### Deeplinks and config file

Use `spacesrenamer://` URLs from Shortcuts, browsers, or another launcher:

| URL | Action |
| --- | --- |
| `spacesrenamer://settings` | Open Settings |
| `spacesrenamer://renamer` | Toggle the rename popover |
| `spacesrenamer://profile/switch/<uuid>` | Switch profile |
| `spacesrenamer://naming/manual` | Use manual names |
| `spacesrenamer://naming/applications` | Use Apps in Space mode |
| `spacesrenamer://naming/yabaiLabels` | Use yabai labels mode |
| `spacesrenamer://space/<uuid>/name?name=<encoded>` | Set a Space name |
| `spacesrenamer://status` | Write status JSON to the legacy `/tmp/spaces-renamer-status-$UID.json` path; `sr` uses a private per-request reply file |

For external profile management, Spaces Renamer watches `~/.config/spacesrenamer/config.toml` and applies changes live:

```toml
[settings]
# naming_mode = "manual" # manual, applications, or yabaiLabels
# menu_bar_display = "icon" # icon, spaceName, or spaceNumberAndName
# show_duplicate_apps = false

[profiles.Work]
# uuid = "00000000-0000-0000-0000-000000000000"
# "space-uuid" = "Code"
```

---

## Building from source

Requirements: macOS 13+, Xcode 15+, and [`scdoc`](https://git.sr.ht/~emersion/scdoc).

```bash
brew install scdoc
git clone https://github.com/wiggly-sheets/spaces-renamer.git
cd spaces-renamer
make universal
```

`make universal` builds the app and Dock bundle, packages the current arm64e injection payload, and verifies all architecture slices.

| Artifact | Architectures |
| --- | --- |
| `SpacesRenamer.app` | `arm64`, `x86_64` |
| `spaces-renamer.bundle` | `arm64e`, `x86_64` |
| `injection/lib/spaces-renamer.dylib` | `arm64e` |

Useful targets:

```bash
make app                # Build the menu-bar app
make plugin             # Build the Dock bundle
make package-injection  # Refresh the arm64e payload
make dmg VERSION=1.0.0  # Create a distributable DMG
make test               # Run repository contract tests
```

## Security and compatibility

The Dock hook uses private macOS APIs and runs inside the Dock process. macOS updates can change the Mission Control layer hierarchy, so the injected component is deliberately defensive and falls back to normal Dock behavior when it cannot safely find the expected layers.

To inject manually, the repository contains:

```bash
./injection/run.sh
```

Do not run it casually. It needs the prerequisites described above and asks for administrator authorization. The exact setup commands, including SIP and NVRAM changes, are intentionally not automated because they weaken system protections. Building the project is safe: it does not inject, alter boot arguments, change SIP, or restart Dock.

For performance investigation, the bundle emits `os_signpost` data under subsystem `com.wiggly-sheets.spaces-renamer`, category `DockHook`. Attach Instruments to Dock and use Points of Interest or Time Profiler while opening Mission Control.

## Data and privacy

Preferences stay on your Mac:

```text
~/Library/Application Support/SpacesRenamer/preferences.json
```

For Dock compatibility, the app also publishes the active mapping to these legacy plist files:

```text
~/Library/Containers/com.alexbeals.spacesrenamer/com.alexbeals.spacesrenamer.plist
~/Library/Containers/com.alexbeals.spacesrenamer/com.alexbeals.spacesrenamer.currentspaces.plist
```

Existing names are migrated into the Work profile on first launch. The app does not need to upload your Space names or window labels to provide its core functionality.

## License

Spaces Renamer is available under the [MIT License](LICENSE).
