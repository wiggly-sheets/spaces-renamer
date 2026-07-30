# Changelog

## Unreleased

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
