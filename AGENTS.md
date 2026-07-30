# Spaces Renamer Project Guide

## Purpose

Spaces Renamer gives macOS Spaces persistent names in Mission Control. The
project has two cooperating products:

1. `SpacesRenamer.app` is the user-facing SwiftUI menu bar application.
2. `spaces-renamer.bundle` is an Objective-C bundle injected into Dock to
   replace Mission Control's Space labels.

Keep this split. Swift is appropriate for application state and UI, while the
injected bundle should remain Objective-C because it hooks private Objective-C
classes and `CALayer` methods inside Dock.

The supported deployment target is macOS 13 or newer.

## Repository Layout

- `SpacesRenamer/AppDelegate.swift`
  - Application lifecycle.
  - Status item and popover.
  - Settings window.
  - Global hotkey.
  - Native Space and application notifications.
  - Debounced yabai event socket.
- `SpacesRenamer/PreferencesStore.swift`
  - Persistent profiles and active profile.
  - Naming mode.
  - Menu bar visibility and display mode.
  - Hotkey and launch-at-login state.
  - Compatibility plist publication for the injected bundle.
- `SpacesRenamer/SpaceStore.swift`
  - Reads current displays and Spaces through private CoreGraphics APIs.
  - Queries yabai for Space labels and real application windows.
  - Applies the same real-window predicate used by Spacemap.
- `SpacesRenamer/RenamerView.swift`
  - SwiftUI renaming popover.
- `SpacesRenamer/SettingsView.swift`
  - SwiftUI settings for General, Profiles, Hotkey, and Naming.
- `spaces-renamer/spacesRenamer.m`
  - Dock/Mission Control hook and label layout.
- `spaces-renamer/ZKSwizzle.{h,m}`
  - Objective-C runtime swizzling support.
- `injection/`
  - Current standalone injection script and arm64e payload.
  - This is the active injection implementation; injection is not yet managed
    by the GUI application.
- `Makefile`
  - Canonical local build and architecture verification commands.

## Build and Verification

Use the Makefile instead of constructing one-off Xcode commands:

```bash
make app
make plugin
make package-injection
make universal
make verify
```

Expected architectures:

- GUI app: `arm64 x86_64`
- Dock bundle: `arm64e x86_64`
- Packaged injector payload: `arm64e`

`make package-injection` extracts the current arm64e slice into
`injection/lib/spaces-renamer.dylib`. `make universal` builds both products,
updates that payload, and runs architecture verification.

The build uses `CODE_SIGNING_ALLOWED=NO`, so local products are ad-hoc or
linker-signed. Do not assume a stable Developer ID signature is present.

Before committing, run at minimum:

```bash
make universal
git diff --check
```

For injected-code changes, also run the Clang static analyzer:

```bash
xcodebuild \
  -project spaces-renamer.xcodeproj \
  -scheme spaces-renamer \
  -configuration Release \
  -derivedDataPath .build/Analyze \
  CODE_SIGNING_ALLOWED=NO \
  'ARCHS=arm64e' \
  analyze
```

## Application Behavior

### Menu Bar

The status item uses the `rectangle.grid.2x2` SF Symbol by default. General
settings allow:

- showing or hiding the menu bar item;
- displaying the icon;
- displaying the current Space name, such as `Code`;
- displaying its number and name, such as `1. Code`.

The text reflects the status item's display when possible and falls back to the
first current Space. It updates without relaunching when the active Space,
profile, naming mode, or generated name changes.

If the menu bar item is hidden, launching the already-running app opens
Settings. The global hotkey also opens Settings when there is no visible status
item.

### Profiles and Manual Names

Profiles provide independent name mappings keyed by macOS Space UUID. Work and
Home are created by default. Switching profiles republishes the current mapping
immediately; Dock and the GUI do not need to relaunch.

### Naming Modes

There are three naming modes:

1. Manual Profiles
2. Apps in Space
3. yabai Space Labels

Both generated modes intentionally require yabai. Do not restore the old
WindowServer/native application-detection fallback; it did not reliably
distinguish visible user windows from background and placeholder windows.

Apps mode:

- queries `yabai -m query --spaces` and `--windows`;
- accepts standard root windows only;
- excludes hidden, minimized, zero-sized, background, and placeholder records;
- orders windows left-to-right, then top-to-bottom;
- removes duplicate app names by default;
- can optionally list every window, producing names such as
  `Safari · Safari`;
- publishes at most the first three application names.

The relevant real-window test must stay aligned with Spacemap:

- role is `AXWindow`;
- subrole is `AXStandardWindow`;
- `root-window` is not false;
- valid window ID, application, Space, and nonzero frame;
- not hidden or minimized.

### Automatic Updates

Generated names do not poll. `YabaiEventMonitor` creates a per-user Unix socket
and registers yabai signals for relevant application, window, Space, display,
and Mission Control events. Bursts are debounced before querying yabai.

Native `NSWorkspace.activeSpaceDidChangeNotification` updates the Space
snapshot and menu bar label.

## Persistence and Dock Compatibility

Modern settings are stored at:

```text
~/Library/Application Support/SpacesRenamer/preferences.json
```

The injected bundle still consumes the legacy compatibility files:

```text
~/Library/Containers/com.alexbeals.spacesrenamer/com.alexbeals.spacesrenamer.plist
~/Library/Containers/com.alexbeals.spacesrenamer/com.alexbeals.spacesrenamer.currentspaces.plist
```

Do not change these paths or the `spaces_renaming` compatibility contract
without updating both the Swift app and injected bundle together.

## Dock Hook Performance

The Dock hook runs inside a system process. Keep work in swizzled `setFrame`
paths minimal.

Implemented optimizations include:

- plist parsing cached until either file modification date changes;
- discovered `ECTextLayer` descendants cached with associated objects;
- CoreText width measurements cached by font, size, and string;
- KVO registration performed once per text layer;
- associated layout values only mutated when their value changes;
- frame refreshes skipped for unchanged layouts;
- changed layouts refresh only affected Space-label subtrees;
- original and superclass swizzle implementations cached per call site;
- monitor and selected-Space searches avoid temporary collections;
- manual-memory ownership issues and a legacy swizzle parser bug fixed.

The bundle emits `os_signpost` instrumentation with:

- subsystem: `com.wiggly-sheets.spaces-renamer`
- category: `DockHook`
- interval: `ApplyNames`
- event: `ReloadPlists`

Use Instruments Points of Interest or Time Profiler attached to Dock. Preserve
these signposts when changing the hot path.

Do not restore the old broad `refreshFramesSur` traversal unless a macOS update
proves targeted refresh insufficient. If layout compatibility requires broader
work, measure it and constrain it to the smallest safe subtree.

## Current Injection Pipeline

The repository pipeline is:

1. `make package-injection` creates the current arm64e payload.
2. `injection/run.sh` validates Apple silicon and required NVRAM boot arguments.
3. The script clears extended attributes.
4. It runs the signed `dylinject` executable through `sudo`.
5. `dylinject` loads `spaces-renamer.dylib` into Dock.

The supplied `dylinject` executable is arm64e-only and calls
`task_for_pid`/Mach VM APIs. Root authorization is currently required.

Injection requires reduced macOS security protections. Never run the injection
script, modify boot arguments, change SIP/AMFI settings, install a privileged
helper, or restart Dock without explicit user approval.

Do not add a MacEnhance dependency.

### External yabai Setup

The developer's current machine triggers a separate injection copy from
`~/.config/yabai/yabairc` on startup and `dock_did_restart`. That config points
to `~/dotfiles/mac/tweaks/spacesrenamer/run.sh`, not this repository.

This external copy can become stale and must not be treated as part of the
portable project. Avoid adding more dependencies on personal dotfiles.

### Planned App-Managed Injection

App-managed injection has been designed but is not implemented.

The preferred design is:

- embed the injector and payload inside `SpacesRenamer.app`;
- add an Injection settings section and explicit health states;
- use an `SMAppService` launch daemon with a narrowly scoped XPC interface;
- request one system-level approval rather than invoking arbitrary shell
  commands;
- allow the helper to inject only the fixed, validated bundled payload;
- have the injected bundle report its Dock PID and payload version;
- observe Dock restarts and request reinjection when enabled;
- remove the personal yabairc hook only after the app-managed path is proven.

A stable signing identity is a prerequisite for a production-quality
privileged-helper relationship. Do not silently fall back to a broad sudoers
rule or deprecated `AuthorizationExecuteWithPrivileges`.

## Native App Management

- Launch at login uses `SMAppService.mainApp`.
- The app can offer to move itself to `/Applications`.
- Reopening an already-running app opens Settings.
- The application is an accessory app (`LSUIElement`) and must retain a
  functioning status item or Settings reopen path.

## Private API and Compatibility Cautions

This project intentionally uses private macOS APIs and injects into Dock.
Mission Control's private layer hierarchy can change between macOS releases.

When adapting to a new macOS version:

- validate the layer hierarchy before indexing children;
- fail by calling the original implementation instead of crashing Dock;
- keep injection changes arm64e-compatible;
- test repeated Mission Control opens, Space switches, profile switches,
  generated-name changes, and Dock restarts;
- check both single-display and multi-display layouts;
- confirm unnamed Spaces still render normally.

Never assume a successful injector exit alone proves that the bundle is active.
Use a bundle-originated handshake when app-managed injection is implemented.

## Repository Hygiene

- Keep generated build products under `.build/`.
- Do not commit `.DS_Store`, Xcode user data, DerivedData, preference files, or
  unrelated local artifacts.
- The tracked `injection/lib/spaces-renamer.dylib` is intentional and must match
  the current source when injected behavior changes.
- Preserve unrelated user changes in a dirty worktree.
- Use `apply_patch` for source edits.
- Do not remove the Objective-C hook merely to claim a pure-Swift codebase.

## Remaining Priorities

1. Implement app-managed injection with a properly signed, narrowly scoped
   privileged helper.
2. Add an injection handshake, health status, version reporting, and
   idempotency.
3. Establish Developer ID signing and a reproducible release pipeline.
4. Add automated tests for preference migration, name formatting, profile
   switching, and yabai JSON filtering.
5. Continue validating private Mission Control layer compatibility on new
   macOS releases.
