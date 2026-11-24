<div align="center">

  <img src="docs/app-icon.png" width="128" alt="Spaces Renamer app icon" />

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
    <img src="https://img.shields.io/badge/Swift-5.0-F05138?logo=swift&logoColor=white" alt="Swift 5" />
    <img src="https://img.shields.io/badge/macOS-14%2B-Apple%20silicon-000000?logo=apple" alt="macOS 14 or later, Apple silicon" />
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

It is a native macOS menu-bar app paired with a small bundle injected into the process that draws the Spaces bar. Profile and name changes are published immediately—there is no need to restart the app or the Spaces-bar host.

> [!WARNING]
> Showing names inside Mission Control requires injecting a bundle into a system process. This currently needs Apple silicon, the `-arm64e_preview_abi` boot argument, reduced macOS security protections, and the system Library Validation exception. Read [Security and compatibility](#security-and-compatibility) before enabling it.

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
- One injection path: a per-user **MIP** loader, no root and no background service
- Apple silicon only: menu-bar app (`arm64`), Dock bundle and injection payload (`arm64e`)

Generated naming modes require [yabai](https://github.com/koekeishiya/yabai). Apps mode deliberately filters out background, minimized, hidden, zero-sized, and placeholder windows so labels reflect the apps you are actually using.

---

## Installation

### Download the app

macOS 14 or later on an Apple silicon Mac. Intel builds are no longer provided: the injected hook must be `arm64e`, which Apple silicon hosts require.

1. Download `SpacesRenamer-v{VERSION}.dmg` from [GitHub Releases](https://github.com/wiggly-sheets/spaces-renamer/releases/latest).
2. Open the DMG and drag **SpacesRenamer.app** to **Applications**.
3. Open the app. If macOS blocks the unsigned build, right-click it in Finder, choose **Open**, then confirm **Open**. Alternatively:

   ```bash
   xattr -dr com.apple.quarantine /Applications/SpacesRenamer.app
   ```

Or install the Homebrew cask (signed releases only; prereleases skip the cask):

```bash
brew tap wiggly-sheets/homebrew-tap
brew trust wiggly-sheets/homebrew-tap
brew install --cask spacesrenamer
```

The cask declares `depends_on arch: :arm64`, so `brew install --cask` refuses an Intel Mac with a clear message instead of installing an app that cannot work.

### Enable Mission Control names

On first launch the app asks for your consent before it attaches to the Spaces-bar process. The grant persists: with **Keep Dock Renaming Active** on, the app re-injects automatically at login and whenever the host process (re)launches, so a Dock or WindowManager restart does not turn renaming off. You can still activate or deactivate manually any time.

Injecting needs four prerequisites, each checked in **Settings → Diagnostics**:

1. **Apple silicon.**
2. **System Integrity Protection (SIP)** disabled, or reduced to the documented narrower configuration (filesystem, debugging, and NVRAM protections off). This is the one step the app cannot automate—SIP can only be disabled from Recovery. The Diagnostics pane copies the command (`csrutil disable`) for you; the Recovery reboot is manual.
3. **The `-arm64e_preview_abi` boot argument.** In **Settings → Diagnostics**, the **Enable & restart…** button adds the flag for you with an administrator prompt (preserving any existing boot-args) and offers to reboot. The flag takes effect on the next reboot.
4. **The system Library Validation exception.** The user-owned loader is ad-hoc signed, so a platform host only maps it when `DisableLibraryValidation` is true. Run this once; Settings → Diagnostics can copy it for you:

   ```bash
   sudo defaults write /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation -bool true
   ```

Once the boot argument is active and Library Validation is disabled, activate under **Settings → Injection**, or press **Inject Now** in the menu-bar popover. Activation is unprivileged. Only the boot-argument write and the one-time Library Validation command ask for a password or Touch ID.

Never assume a successful activation means the hook is applied. The bundle self-reports through a preference-domain marker; **Settings → Diagnostics** shows **Plugin version** and **Plugin active in host** green only when that report is current in the running host.

### Injection: targeted MIP loader

Spaces Renamer loads `spaces-renamer.dylib` into the process that draws the Spaces bar—`WindowManager` on macOS 27 and later, `Dock` on earlier releases. The embedded `injector.sh` drives a per-user [MIP](https://github.com/LIJI32/MIP) loader and bundle. The loader is injected into the host only, and its name filter loads the bundle into `WindowManager`/`Dock` alone.

**MIP (targeted, no root, no AMFI flag).** MIP loads a bundle only into the executables named in its `Info.plist`—here `WindowManager` and `Dock`. The app places its own loader and bundle in `~/Library/Application Support/SpacesRenamer/mip`, briefly sets `DYLD_INSERT_LIBRARIES` to that loader, and restarts the host. MIP's name filter then loads the hook only in the host.

No daemon, Mach service, privileged helper, persistent LaunchAgent, or `amfi_get_out_of_my_way` boot argument is involved. That flag disables AMFI system-wide and breaks the JVM; this path does not need it.

> **Heads up:** during the activation window every GUI app launched at that moment inherits the loader. The loader's filter means only `WindowManager` and `Dock` load the renaming bundle. The window lasts only until the host restarts.

To use MIP from a checkout:

```bash
./injection/injector.sh mip on build/SpacesRenamer.mip.bundle   # no root
./injection/injector.sh status
./injection/injector.sh mip off                                # no root
```

### Bundled injection runtime

The app carries a private build of MIP's `loader.dylib` in `Contents/Resources/mip`. It is committed prebuilt, so a fresh Mac needs nothing but `SpacesRenamer.app`: no compiler, no GNU binutils, no separate MIP install. Activation copies the loader and the bundle into `~/Library/Application Support/SpacesRenamer/mip`.

The runtime is `arm64e`, like the hook it loads into the host.

No launchservicesd hook, daemon, LaunchAgent, or system directory is touched.

macOS 27 is the verified target. macOS 26 and earlier use the same Dock host and loader path, but are untested. Releases before 26 may also need hooks from older Spaces Renamer versions to match their Dock layer hierarchy.

Rebuilding the runtime needs GNU binutils (`brew install binutils`); see `injection/mip/README.md`.

### Uninstall

1. **Deactivate** — in the popover or **Settings → Injection**, or from a checkout `injection/injector.sh mip off`. This restarts the host clean.
2. Turn off **Launch at login**, then quit the app.
3. Drag **SpacesRenamer.app** to the Trash, or `brew uninstall --cask spacesrenamer`.
4. Optionally clear the published names:

   ```bash
   defaults delete com.apple.dock SpacesRenamerNames
   defaults delete com.apple.dock SpacesRenamerMonitors
   defaults delete com.apple.WindowManager SpacesRenamerPlugin   # or com.apple.dock on macOS 26 and earlier
   ```

5. If a name still shows, restart the host: `killall WindowManager` (macOS 27+) or `killall Dock`.

---

## Using Spaces Renamer

### Menu bar

Click the square-grid status item to open the popover: one row per display with the current Space highlighted, a **Profile** menu, a gear button for Settings, and a footer with the naming-mode menu, injection status plus **Inject Now**/**Deactivate**, the **Keep Dock Renaming Active** toggle, and **Quit**.

Choose icon, Space name, or number-and-name display in **Settings → General**. The menu-bar text updates live when the active Space, profile, or generated names change. Press **Control–Option–R** from anywhere to open Settings (change it in **Settings → Hotkey**) — the popover itself cannot be opened programmatically. Press Return to commit the active name; closing the popover also saves edited manual names.

### Profiles and naming modes

Manual names belong to profiles, so one set of Spaces can be **Work** during the week and **Home** after hours. Names are stored against stable Space UUIDs and the active profile is republished to the host immediately when it changes.

| Mode | What appears in Mission Control | Requires yabai |
| --- | --- | --- |
| Manual Profiles | The names you assign to each Space | No |
| Apps in Space | Up to three app names, e.g. `Xcode · Safari` | Yes |
| yabai Space Labels | Labels defined in yabai | Yes |

### Command line (`sr`)

Spaces Renamer installs a convenient `sr` symlink at `~/.local/bin/sr` on launch.

```bash
sr status                  # Profile, naming mode, and spaces
sr renamer                 # Open Settings (the popover cannot be opened programmatically)
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
| `spacesrenamer://renamer` | Open Settings (the popover cannot be opened programmatically) |
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

## Troubleshooting

- **Nothing renames after Activate.** Re-run **Settings → Diagnostics**. "Plugin active in host" stays red if SIP is on, the arm64e boot argument isn't set, or the host hasn't restarted since the injector ran. Open Mission Control once so the plugin's first hook fires.
- **"Plugin version" is green but "Plugin active in host" is red.** The plugin loaded into a host that has since been replaced (stale marker). Restart the host (`killall WindowManager` / `killall Dock`) or press **Inject Now**.
- **WindowManager crash-loops.** Pull it out of the launch loop, then relaunch it:

  ```bash
  launchctl bootout gui/$(id -u)/com.apple.WindowManager.agent
  launchctl bootstrap gui/$(id -u) /System/Library/LaunchAgents/com.apple.WindowManager.plist
  ```

  If the loop started right after activation, `injection/injector.sh mip off` is the documented recovery—it removes the environment variable and restarts the host clean.
- **Host dies with `Killed: 9` shortly after launch.** On an arm64e preview ABI the kernel rejects an improperly signed/loaded library. This is usually the `-arm64e_preview_abi` boot argument having gone missing after a macOS update—re-add it (`sudo nvram boot-args=<existing> -arm64e_preview_abi`) and reboot.
- **Why does "Plugin active" stay red even though activation succeeded?** The handshake is a self-report, not an injector exit code. The bundle writes `Version`/`Build`/`HostPID`/`HostBundleID`/`LoadedAt`/`FirstHookAt` into its host's own preference domain; the first hook firing is what sets `FirstHookAt`. Inspect it with `defaults read com.apple.WindowManager SpacesRenamerPlugin` (or `defaults read com.apple.dock SpacesRenamerPlugin` on macOS 26 and earlier).
- **Names stop applying after a host restart.** The loader has no daemon and must run its brief activation again. When the app is running, it re-injects automatically; otherwise press **Inject Now**.
- **MIP activation is greyed out or fails.** The build has no embedded `loader.dylib`; rebuild with `make` so the app carries the loader and bundle.
- **Activation reports Library Validation is enabled.** Run the one-time command from [Enable Mission Control names](#enable-mission-control-names), then activate again.
- **Gatekeeper won't open the app.** It's an unsigned build; run `xattr -dr com.apple.quarantine /Applications/SpacesRenamer.app`.

---

## Building from source

Requirements: macOS 14+ on an Apple silicon Mac, Xcode 15+, and [`scdoc`](https://git.sr.ht/~emersion/scdoc).

```bash
brew install scdoc
git clone https://github.com/wiggly-sheets/spaces-renamer.git
cd spaces-renamer
make build-all
```

`make build-all` builds the app and Dock bundle, packages the current arm64e injection payload, and verifies the arm-only slices.

| Artifact | Architectures |
| --- | --- |
| `SpacesRenamer.app` | `arm64` |
| `spaces-renamer.dylib` | `arm64e` |
| `injection/lib/spaces-renamer.dylib` | `arm64e` |
| `injection/mip` (private MIP runtime) | `arm64e` |

Useful targets:

```bash
make help               # List every target (default)
make build              # Build the SwiftPM package
make test               # Run the changelog check and the repository contract tests
make run                # Install into ~/Applications and launch
make app                # Build the menu-bar app
make verify             # Verify the arm-only slices and the embedded payload
make dmg VERSION=1.0.0  # Create a distributable DMG
make release-artifacts VERSION=1.0.0  # DMG plus the checksum file the tap reads
make release-notes VERSION=1.0.0      # Preview the changelog section
make release VERSION=1.0.0  # Bump, test, build, verify, commit and tag
make clean              # Remove the build output
```

Targets of the build itself:

```bash
make build-all         # Build both products, package the payload, verify
make plugin             # Build the Dock bundle
make package-injection  # Refresh the arm64e payload
make bundle             # Assemble the MIP bundle
make verify             # Verify the arm-only slices and embedded payload
```

The version comes from the tag and from nowhere else. `make release VERSION=1.0.0`
moves `[Unreleased]` to that version, stamps it into the bundle, runs the tests,
builds and verifies the artifacts, commits the changelog bump and creates the
tag locally. It refuses to tag when the bundle reports another version, and it
never pushes. The release workflow takes the version from the tag it runs for.

## Security and compatibility

The injected bundle uses private macOS APIs inside the Spaces-bar host. Mission Control's private layer hierarchy can change between macOS releases, so the onboard hook is deliberately defensive: it validates the layer tree before touching anything and falls back to normal host behavior rather than crashing.

Injecting code into a system process requires reduced macOS security protections, which this project does not hide:

- **Apple silicon** (the app is `arm64`, and the host processes are `arm64e` binaries).
- **SIP disabled** or reduced so filesystem, debugging, and NVRAM protections are off. Only you can change this, from Recovery.
- **The `-arm64e_preview_abi` boot argument**, which the app can add for you via an administrator prompt. It takes effect on the next reboot.
- **The system Library Validation exception** (`DisableLibraryValidation=true`). The app copies the one-time command; running it needs an administrator prompt.

To inject manually from a checkout:

```bash
./injection/injector.sh mip on build/SpacesRenamer.mip.bundle   # no root
./injection/injector.sh status
./injection/injector.sh mip off                                # deactivate
```

Only the boot-argument write and the one-time Library Validation command ask for administrator authorization through the standard macOS dialog. The injection path is unprivileged. The repository never changes SIP, reboots your Mac, installs a privileged helper, or runs the injector without your approval. Building the project is safe: it does not inject, alter boot arguments, change SIP, or restart the host.

For performance investigation, the bundle emits `os_signpost` data under subsystem `com.wiggly-sheets.spaces-renamer`, category `DockHook`. Attach Instruments to the host and use Points of Interest or Time Profiler while opening Mission Control.

## Data and privacy

Preferences stay on your Mac:

```text
~/Library/Application Support/SpacesRenamer/preferences.json
```

The app and the injected bundle communicate through live preference domains, not files (the host runs sandboxed and can read `com.apple.dock` but not your home folder):

| Domain | Key | Written by | Content |
| --- | --- | --- | --- |
| `com.apple.dock` | `SpacesRenamerNames` | app | `{ space uuid : name }` |
| `com.apple.dock` | `SpacesRenamerMonitors` | app | the `CGSCopyManagedDisplaySpaces` array |
| `com.apple.WindowManager` or `com.apple.dock` | `SpacesRenamerPlugin` | injected bundle | `Version`, `Build`, `HostPID`, `HostBundleID`, `LoadedAt`, `FirstHookAt` |

Inspect any of them with e.g. `defaults read com.apple.dock SpacesRenamerNames`. The app does not need to upload your Space names or window labels to provide its core functionality.

## License

Spaces Renamer is available under the [MIT License](LICENSE). It is a modern rewrite of the original [Spaces Renamer](https://github.com/dado3212/spaces-renamer) by Alex Beals, updated for macOS 14+ with targeted MIP injection on Apple silicon.
