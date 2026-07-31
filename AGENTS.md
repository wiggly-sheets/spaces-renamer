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

### App-Managed Injection (v1.0.0)

App-managed injection is designed for v1.0.0. The chosen design (see
`docs/adr/0001-app-managed-injection-elevation.md` for the decision and its
constraints):

- embed the injection stack (`injection/run.sh`, `dylinject`, and
  `spaces-renamer.dylib`) inside `SpacesRenamer.app` at build time;
- elevate via `osascript` `do shell script ... with administrator privileges`,
  which shows the standard macOS password / Touch ID dialog — not the
  deprecated `AuthorizationExecuteWithPrivileges`, no sudoers rule, no new
  trust boundary;
- ask consent at first launch (or whenever injection is off); the grant
  persists and later launches auto-inject silently;
- reinject automatically on Dock restart and computer restart (via the
  existing launch-at-login); toggle in Settings;
- keep manual re-inject affordances in Settings and the menu bar for recovery
  when Dock crashes or injection is inactive while the app runs;
- surface health state through the bundle-originated handshake (Dock PID and
  payload version). Never assume a successful injector exit alone proves the
  bundle is active.

No Developer ID Application certificate is currently available. That blocks
the production privileged-helper path: the `SMAppService` launch daemon with a
narrowly scoped XPC interface remains the designed post-signing upgrade and
must wait for a stable signing identity. Do not silently fall back to a broad
sudoers rule or deprecated `AuthorizationExecuteWithPrivileges`. Remove the
personal yabairc hook only after the app-managed path is proven.

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

## v1.0.0 Roadmap

In priority order:

- [ ] Finalize GitHub Releases workflow and Homebrew tap test
  - Fix the artifact-name mismatch (`SpacesRenamer-{tag}.app.zip` vs the
    cask's `SpacesRenamer-v{version}.zip`).
  - Auto-bump the cask in the release workflow: update
    `homebrew/spacesrenamer.rb` (version + sha256), commit to master, and push
    the same file to the separate tap repo `wiggly-sheets/homebrew-spacesrenamer`
    using the existing `GH_TOKEN` secret.
  - Post-release tap-test job (non-gating): `brew tap` + `brew install --cask`
    + version assert on the arm64 CI runner; Intel stays a documented manual
    pre-release check.
  - Release notes extracted from `CHANGELOG.md`; generic fallback; never fail
    the release over missing changelog text.
  - `--prerelease` only for prerelease tags (tag contains `-`).
- [ ] Create DMG with `create-dmg` (custom background/instructions) instead of zip for GitHub Release / Homebrew
  - DMG-only: ship `SpacesRenamer-v{version}.dmg` + `.sha256`; cask URL points
    at the `.dmg`; zip removed from Releases.
  - Add `packaging/` with the create-dmg invocation and a placeholder
    background (plain white/grey, "Drag into Applications" instructions baked
    in); add a `make dmg` target.
- [ ] Add app-managed injection for all-in-one workflow (started in separate branch)
  - Implementation branch: `feat/app-managed-injection` (was
    `codex/app-managed-injection`). Design in the App-Managed Injection section
    above and `docs/adr/0001-app-managed-injection-elevation.md`. The XPC
    helper from the branch's first pass is cut; `InjectionManager` UI/state and
    the Dock handshake are reused.
- [ ] Clean up and remove all redundant branches
  - Delete `feature/config-file` (local; work already on master), and
    `feature/releases-docs` (local + remote; commits already on master).
  - Keep `feat/app-managed-injection` as the item-3 working branch.
- [ ] (Maybe) Get app to properly refresh names of apps on current space after app add/remove — no need to switch spaces for consistent updates. More performant, efficient, reliable app name updates using yabai/system calls
  - Deferred to post-1.0.0.

## Remaining Priorities

1. Implement the production privileged-helper path (`SMAppService` launch
   daemon + scoped XPC) once a Developer ID signing identity exists; v1.0.0
   ships app-managed injection via system admin-prompt elevation instead.
2. Add an injection handshake, health status, version reporting, and
   idempotency.
3. Establish Developer ID signing and a reproducible release pipeline.
4. Add automated tests for preference migration, name formatting, profile
   switching, and yabai JSON filtering.
5. Continue validating private Mission Control layer compatibility on new
   macOS releases.

## Agent skills

### Issue tracker

Issues live as markdown files under `.scratch/<feature-slug>/`. See `docs/agents/issue-tracker.md`.

### Triage labels

Labels match the defaults: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout: one `CONTEXT.md` at the root, ADRs under `docs/adr/`. See `docs/agents/domain.md`.
