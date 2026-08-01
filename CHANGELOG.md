# Changelog

## Unreleased

## 1.0.0 (2026-08-01)

### Added

- [Ticket 10] Embed injection stack in app bundle: app bundle now carries full injection stack at build time (injection script, injector executable, payload) at a stable, code-signed-safe location
- [Ticket 11] GUI-driven injection with admin-prompt elevation: Settings → Injection shows health, Dock PID, payload version, and recovery controls; clicking Inject runs the embedded stack via the system password/Touch ID prompt; health reflects the Dock handshake, not just injector exit
- [Ticket 12] Persistent consent flow: first launch asks for consent; a grant persists and enables automatic injection without another app-level consent prompt (the macOS administrator prompt still appears for each privileged run); declining leaves injection off and does not prompt again on every launch
- [Ticket 13] Automatic reinjection: with consent granted, the app keeps itself injected — reinjects on Dock restart and at computer restart via existing launch-at-login; controlled by Settings toggle
- [Ticket 14] Recovery affordances: two-click recovery when app running but injection inactive (e.g., Dock crashed/restarted while automation was off) — re-inject entry in menu bar plus Settings button; inactive state surfaced in menu bar + Settings
- Space renaming in Settings, using the same per-display editor as the menu-bar popover
- An `sr(1)` manual page generated with scdoc and bundled with the app

### Changed

- Injection setup now requires `-arm64e_preview_abi`, treats `amfi_get_out_of_my_way=1` as conditional troubleshooting, documents full and partial SIP configurations, and avoids nested `sudo` when the bundled script is already elevated
- Dock-hook health now distinguishes payload loading from Mission Control verification, and the optimized hook uses a geometrically filtered `CALayer` entry path compatible with macOS 26.6
- Yabai-driven application names now use a bounded event throttle with a trailing convergence pass, so move/resize bursts cannot postpone new-window names until the next Space change; Mission Control entry forces an immediate snapshot
- Generated app bundles, legacy build directories, and Xcode project backup files are excluded or removed from the repository

## 0.9.0 (2026-07-30)

### Added

- CLI tool (`sr`) for status, renamer, settings, profile switching, naming mode, and Space naming commands. Symlinked to `~/.local/bin/sr` on app launch.
- Deeplink URL scheme (`spacesrenamer://`) for integration from browsers, Shortcuts, or any URL opener. Supports all CLI commands plus direct Space naming with URL-encoded names.
- Config file (`~/.config/spacesrenamer/config.toml`) for external profile and settings management. Watched live — no restart needed.
- yabai health check in Settings: runs `yabai -m query --spaces` to confirm yabai is actually responding (replaces unreliable socket path guessing).
- Architecture table in README showing expected slices per artifact.

### Changed

- README reorganized with Usage section covering Menu Bar, CLI Tool, Deeplinks, and Config File.
- yabai status checker simplified to single green/red indicator based on command response.

### Fixed

- CLI `sr status` now triggers a deeplink to write the status file before reading it, so it always returns fresh data.

## 2025-06-10

### Added

- Profiles, live profile switching, settings, a global renamer hotkey, and optional automatic app-based names.
- Native launch-at-login and Applications-folder relocation controls.
- Native shortcut recorder in Settings with live global-hotkey updates.
- A General setting to hide the menu bar icon, with Settings reopened when the running app is launched again.
- A third naming mode that mirrors live yabai Space labels alongside manual profiles and app-based names.
- An opt-in Apps-mode setting that lists each real window separately, including repeated application names.
- A menu bar display setting for the app icon, current Space name, or Space number and name.

### Changed

- Rebuilt the user-facing app in SwiftUI while retaining the proven Dock injection implementation.
- App and Dock injection bundle now build as universal binaries.
- Refreshed app and menu bar artwork.
- Dynamic naming uses yabai's live Space labels or spaces/windows data directly.
- Automatic names now update from debounced yabai window, Space, display, and Mission Control events instead of periodic polling.
- yabai application visibility and Space/display change signals now reconcile dynamic names without polling.
- The injected Dock hook now caches unchanged plist data, discovered text layers, and CoreText measurements; registers observers once; and refreshes only changed Space-label subtrees.

### Fixed

- Ignore yabai placeholder, hidden, minimized, background, and nonstandard window records when generating automatic Space names, using the same standard-root-window test as Spacemap.
- Order automatically generated app names by their windows' on-screen position, left to right and then top to bottom.
- Install the `NSApplicationDelegate` explicitly at startup so menu-bar setup, native move prompting, hotkeys, and settings initialization actually run.
- Avoid Tahoe/Thaw's stale hidden-item record by using the fork's bundle identity, creating the status item after app launch, and deferring the Applications-folder prompt until the item is published.
- Give the Tahoe status item a new persistent identity and use an icon-only SF Symbol.

### Removed

- Removed the unreliable private WindowServer fallback for automatic app detection; automatic naming now clearly requires yabai.
- Removed the retired AppKit storyboard UI, legacy login scripts, LetsMove framework, unused artwork, screenshots, release archive, and MacEnhance cleanup script.
