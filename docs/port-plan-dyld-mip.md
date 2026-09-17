# Port Plan: DYLD/MIP Injection into SpacesRenamer

> **Status**: Phase 1 COMPLETE (DYLD/MIP injection implemented and verified); Phase 2 COMPLETE; Phase 3 COMPLETE  
> **Date**: 2026-09-17  
> **Scope**: Replace `dylinject`/`task_for_pid` injection with DYLD/MIP approach from fork (Quelaan1/spaces-renamer v2.1.1)  
> **Preserve**: All existing features — profiles, yabai space naming, auto naming, preferences, hotkey, login item

---

## 1. Legacy State (pre-port, replaced by Phase 1)

### Architecture
- **Build**: Xcode project (`spaces-renamer.xcodeproj`), two schemes (SpacesRenamer app, spaces-renamer bundle)
- **App**: `@main class AppDelegate` (854 lines), manages status item, popover, settings, hotkey, yabai events, injection lifecycle
- **Injection**: `InjectionManager.swift` (616 lines) — complex state machine using `dylinject` binary via `task_for_pid`/Mach VM APIs
- **Communication**: Legacy plist files (`com.alexbeals.spacesrenamer.plist`, `com.alexbeals.spacesrenamer.currentspaces.plist`) + JSON handshake at `/tmp/spaces-renamer-injection-{uid}.json`
- **Dock Hook**: `spacesRenamer.m` (945 lines) — swizzles `CALayer setFrame:` and `ECTextLayer` for `SpacesListLayoutController`
- **Build artifacts**: `injection/lib/dylinject` (arm64e binary), `injection/lib/spaces-renamer.dylib`, `injection/run.sh`

### Injection Flow (Legacy)
1. `InjectionManager` checks prerequisites (arm64e_preview_abi boot arg, SIP status)
2. `InjectionCommandBuilder` constructs privileged shell command with SHA256 integrity checks
3. `NSAppleScript` runs `do shell script ... with administrator privileges` to invoke `dylinject`
4. `dylinject` uses `task_for_pid`/Mach VM APIs to inject `spaces-renamer.dylib` into Dock
5. Handshake via `/tmp/spaces-renamer-injection-{uid}.json` confirms injection
6. `InjectionLifecycle` enums define states: `unsupported`, `prerequisitesMissing`, `ready`, `injecting`, `restartingDock`, `loaded`, `injected`, `updateRequired`, `authorizationCancelled`, `error`

### Key Files
| File | Lines | Purpose |
|------|-------|---------|
| `SpacesRenamer/AppDelegate.swift` | 854 | Main app delegate, injection lifecycle |
| `SpacesRenamer/InjectionManager.swift` | 616 | State machine, dylinject orchestration |
| `SpacesRenamer/InjectionLifecycle.swift` | 43 | Injection intent/operation enums |
| `SpacesRenamer/InjectionCommandBuilder.swift` | 35 | Privileged shell command builder |
| `SpacesRenamer/PreferencesStore.swift` | 484 | Profiles, naming modes, legacy plist publishing |
| `SpacesRenamer/SpaceStore.swift` | 222 | CoreGraphics Spaces, yabai queries |
| `SpacesRenamer/SettingsView.swift` | 704 | Injection settings UI with state-based views |
| `SpacesRenamer/Utils.swift` | 20 | Legacy container paths |
| `spaces-renamer/spacesRenamer.m` | 945 | Dock hook, CALayer swizzling |
| `spaces-renamer/ZKSwizzle.{h,m}` | 131/273 | Objective-C runtime swizzling |
| `Makefile` | — | Xcode-based build |
| `injection/run.sh` | — | dylinject via sudo |
| `injection/lib/dylinject` | — | arm64e binary |
| `injection/lib/spaces-renamer.dylib` | — | Injected payload |

---

## 2. Target State (Fork Approach)

### Architecture
- **Build**: Swift Package Manager (`Package.swift`, swift-tools-version:6.0) + Makefiles
- **App**: `@main struct SpacesRenamerApp` with `@Observable` models, `MenuBarExtra`
- **Injection**: `Injector.swift` (270 lines) — DYLD/MIP enum, `ActivationModel`, `PluginMarker`
- **Communication**: `com.apple.dock` preference domain keys (`SpacesRenamerNames`, `SpacesRenamerMonitors`, `SpacesRenamerPlugin`)
- **Dock Hook**: `spacesRenamer.m` (823 lines) — macOS 27 `WindowManager SpacesBar` support, `setBounds:/layoutSublayers`, display identity matching, retry logic
- **Build artifacts**: `injector.sh` (224 lines) — DYLD LaunchAgent + MIP bundle management

### Injection Flow (Target)
1. `Injector` determines activation method (DYLD or MIP)
2. `injector.sh` sets up `DYLD_INSERT_LIBRARIES` via LaunchAgent or MIP bundle
3. No root required — no `task_for_pid`, no `sudo`, no `NSAppleScript`
4. Preference domain keys communicate names from app to Dock bundle
5. Dock bundle reads `com.apple.dock` preference domain for Space names

### Key Fork Files
| File | Lines | Purpose |
|------|-------|---------|
| `SpacesRenamerApp.swift` | — | @main struct, @Observable models, MenuBarExtra |
| `Injector.swift` | 270 | DYLD/MIP enum, ActivationModel, PluginMarker |
| `SpaceHUD.swift` | 113 | Glass-styled HUD on Space change |
| `SpacesStore.swift` | 215 | @Observable, CGSPrivate C module, preference domain |
| `AppSettings.swift` | 29 | UserDefaults-based settings |
| `SpaceCell.swift` | 43 | SwiftUI text field with focus state |
| `DiagnosticsModel.swift` | 232 | 4 checks with one-tap fixes |
| `DiagnosticsView.swift` | 168 | Diagnostics UI + activation section |
| `RenameView.swift` | 125 | Space renaming grid |
| `LoginItem.swift` | 36 | SMAppService.mainApp |
| `Paths.swift` | 23 | Centralized constants |
| `injector.sh` | 224 | DYLD LaunchAgent + MIP bundle management |
| `spacesRenamer.m` | 823 | macOS 27 WindowManager SpacesBar |
| `Package.swift` | — | SwiftPM manifest |
| `Makefile` | — | swift build based |
| `packaging/mip/Info.plist` | — | MIP bundle with MIPExecutableNames filter |

---

## 3. Porting Phases

### Phase 1: Replace Injection Mechanism (COMPLETE)

> **Status: complete.** `make app`, `make plugin`, `make verify`, and `make test` pass. The only failing test, `test_make_dmg.sh`'s "committed background matches fresh render", is pre-existing and environmental — `packaging/` is untouched, and the committed `background.png` hashes differently than a fresh render on this macOS. The decisions made during implementation are recorded in §3.11.

#### 3.1 Replace `InjectionManager.swift`
- **Remove**: `dylinject` orchestration, `task_for_pid`/Mach VM APIs, `NSAppleScript` elevation, SHA256 integrity checks, complex state machine
- **Replace with**: DYLD/MIP-based injection manager
- **New states**: Simpler state model (e.g., `idle`, `checking`, `activating`, `active`, `inactive`, `error`)
- **Key changes**:
  - Replace `InjectionLifecycle` enums with fork-compatible equivalents
  - Replace `InjectionCommandBuilder` with DYLD/MIP activation logic
  - Remove `NSAppleScript` dependency
  - Remove `dylinject` binary dependency
  - Add `ActivationModel` and `PluginMarker` from fork
  - Add `Injector` enum (DYLD vs MIP)

#### 3.2 Replace `InjectionCommandBuilder.swift`
- **Remove**: Privileged shell command construction, SHA256 integrity checks
- **Replace with**: DYLD LaunchAgent configuration or MIP bundle activation commands
- **New approach**: Build `injector.sh` commands or directly configure LaunchAgents

#### 3.3 Replace `InjectionLifecycle.swift`
- **Remove**: `InjectionIntent`, `InjectionOperation`, `InjectionDockRestartAction`, `InjectionLifecyclePolicy`
- **Replace with**: Fork-compatible enums or simplified lifecycle model

#### 3.4 Add `injector.sh`
- **Source**: Adapt from fork's `injector.sh` (224 lines)
- **Purpose**: DYLD LaunchAgent + MIP bundle management
- **Key features**:
  - Sets `DYLD_INSERT_LIBRARIES` environment variable
  - Manages LaunchAgent for persistence
  - Handles MIP bundle registration
  - No root required
- **Location**: `injection/injector.sh` (replaces `injection/run.sh`)

#### 3.5 Update `PreferencesStore.swift`
- **Add**: Preference domain keys (`SpacesRenamerNames`, `SpacesRenamerMonitors`, `SpacesRenamerPlugin`)
- **Keep**: Legacy plist files for backward compatibility during transition
- **Add**: `com.apple.dock` preference domain communication
- **Key changes**:
  - Publish Space names via `CFPreferencesSetAppValue` or equivalent
  - Read/write to `com.apple.dock` domain
  - Maintain legacy plist publishing for Dock bundle compatibility

#### 3.6 Update `SettingsView.swift`
- **Simplify**: Injection settings UI — remove complex state machine views
- **Replace**: State-based injection UI with simpler activation/deactivation controls
- **Add**: DYLD/MIP activation toggle, diagnostics link
- **Keep**: Profile management, naming mode settings, hotkey settings

#### 3.7 Update `AppDelegate.swift`
- **Simplify**: Remove `dylinject`-specific code paths
- **Add**: DYLD/MIP activation calls
- **Keep**: Status item, popover, settings window, hotkey, yabai events, CLI symlinks, deeplink handling
- **Key changes**:
  - Replace `InjectionManager` state machine calls with `Injector` calls
  - Update injection consent flow for DYLD/MIP
  - Update handshake mechanism (preference domain instead of JSON file)

#### 3.8 Update `spacesRenamer.m` (Dock Hook)
- **Add**: macOS 27 `WindowManager SpacesBar` support
- **Add**: `setBounds:/layoutSublayers` method handling
- **Add**: Display identity matching
- **Add**: Retry logic for label application
- **Keep**: `ZKSwizzle` swizzling, `CALayer setFrame:` hook, `ECTextLayer` handling
- **Key changes**:
  - Add `WindowManager` SpacesBar layer detection
  - Add `setBounds:` swizzle for macOS 27 compatibility
  - Add display identity matching for multi-display layouts
  - Add retry logic for label application
  - Keep `os_signpost` instrumentation

#### 3.9 Update `Utils.swift`
- **Replace**: Legacy container paths with preference domain paths
- **Keep**: Any utility functions still needed

#### 3.10 Update `Makefile`
- **Add**: SwiftPM build targets alongside Xcode targets
- **Keep**: Xcode targets for backward compatibility
- **Add**: `make inject` target for `injector.sh`
- **Update**: Architecture verification for DYLD/MIP payloads

#### 3.11 Implementation Notes & Decisions (Phase 1 complete)

Decisions recorded during implementation; where the port diverged from the plan above it is reflected in the file map (§6).

1. **App bundle ID**: stays `com.wiggly-sheets.SpacesRenamer`; the fork's `com.alexbeals.SpacesRenamer` was not adopted.
2. **LaunchAgent label**: `com.wiggly-sheets.SpacesRenamer.injector` (the fork used `com.alexbeals.SpacesRenamer.injector`).
3. **Legacy plists remain a fallback**: the hook reads the `com.apple.dock` preference domain first (`SpacesRenamerNames`/`SpacesRenamerMonitors`) and falls back to the legacy plists.
4. **`injection/run.sh` + `injection/lib/dylinject`**: kept in the repo but no longer embedded (fallback path preserved per plan instruction 7). The new embedded layout is `Contents/PlugIns/spaces-renamer.dylib` (arm64e), `Contents/Resources/injector.sh` (executable), and `Contents/Resources/SpacesRenamer.mip.bundle`.
5. **Handshake**: the old JSON `/tmp` file and the `com.wiggly-sheets.SpacesRenamer.Injected` distributed notification were replaced by the `SpacesRenamerPlugin` preference-domain marker — `Version`/`Build`/`HostPID`/`HostBundleID`/`LoadedAt`/`FirstHookAt` written to the host's own domain and read by `PluginMarker` in `Injector.swift`.
6. **`Utils.swift`**: unchanged; legacy container paths are still needed.
7. **Injection UI in `SettingsView`**: no diagnostics link (DiagnosticsView is Phase 2); a backend picker (DYLD/MIP) + Activate/Deactivate button + status row instead.
8. **Monitors**: `SpaceStore` writes the raw CGS monitors array (with per-space type) to the dock-domain key `SpacesRenamerMonitors`.
9. **`make verify`**: rewritten — one `lipo -verify_arch` per architecture (the multi-arch form trips `lipo: -verify_arch requires exactly one input file` on this machine), checks the new embedded layout, and negatively checks that the old `Contents/Resources/Injection` layout is gone.
10. **New Makefile targets**: `bundle` assembles `build/SpacesRenamer.mip.bundle` from `packaging/mip/Info.plist` + the arm64e dylib; `inject` runs the manual `injection/injector.sh dyld on` path.
11. **Deleted** (not merged into `Injector.swift`): `SpacesRenamer/InjectionCommandBuilder.swift`, `SpacesRenamer/InjectionLifecycle.swift`, `scripts/tests/test_injection_command.{sh,swift}`, `scripts/tests/test_injection_lifecycle.{sh,swift}`. Rewritten: `scripts/embed-injection.sh`, `scripts/tests/test_settings_contracts.sh`, `test_embed_injection.sh`, `test_make_verify.sh`.
12. **Dock hook**: keeps the target's immediate `ZKSwizzleInterface` style (not the fork's `ZKSwizzleInterfaceGroup`), keeps all `os_signpost` instrumentation, and ports the macOS 27 WindowManager SpacesBar path (`setBounds:`/`layoutSublayers` on SpacesBar, `CATextLayer setString:` on PreviewLabel, 60×1/60s retry).

### Phase 2: Add Fork Features (COMPLETE)

> **Status: complete.** `SpaceHUD.swift`, `DiagnosticsModel.swift`/`DiagnosticsView.swift`,
> `SpaceCell.swift`, and `Paths.swift` were added (see §6). SettingsView gained a
> Diagnostics section and a HUD toggle.

#### 2.1 Add `SpaceHUD.swift`
- Glass-styled HUD on Space change
- Uses `@Observable` model

#### 2.2 Add `DiagnosticsModel.swift` + `DiagnosticsView.swift`
- 4 checks with one-tap fixes
- Diagnostics UI + activation section

#### 2.3 Add `SpaceCell.swift`
- SwiftUI text field with focus state
- For space renaming grid

#### 2.4 Add `Paths.swift`
- Centralized constants
- Replace scattered path definitions

#### 2.5 Add `SpaceHUD.swift`
- Glass-styled HUD on Space change

### Phase 3: Build System Migration (COMPLETE)

> **Status: complete.** `make app`, `make app-xcode`, `make verify`, and `make test`
> pass. The only failing test, `test_make_dmg.sh`'s "committed background matches
> fresh render", is the same pre-existing environmental failure noted in Phase 1 —
> `packaging/` is untouched. `test_settings_contracts.sh` passes 45/45; `git diff
> --check` is clean. Decisions recorded below.

#### 3.1 Migrate to SwiftPM
- `SpacesRenamer/Package.swift` (swift-tools-version 6.0, `platforms:
  [.macOS("14.0")]`, `swiftLanguageMode(.v5)`, CGSPrivate C target ported from
  the fork, path-based executable target with excludes) so
  `test_settings_contracts.sh` greps survive.
- `Makefile` `app` target = `swift build` + hand-assembled app bundle at
  `.build/SpacesRenamer.app` (binary, sed'd Info.plist, actool assets,
  PkgInfo, ad-hoc codesign, cli/sr + man copies, `embed-injection.sh`).
- New `app-xcode` target keeps the legacy Xcode recipe for backward
  compatibility; `plugin` stays xcodebuild.

#### 3.2 Migrate to `@main` + `@Observable`
- New `SpacesRenamerApp.swift` (`@main` App + `@NSApplicationDelegateAdaptor`,
  `MenuBarExtra` + `.menuBarExtraStyle(.window)`, `PopoverContent` =
  `RenamerView` + relocated footer).
- `AppDelegate.swift` slimmed to an `NSApplicationDelegateAdaptor` delegate;
  `AppModel.swift` (`@MainActor @Observable`) owns the settings window.
- Models converted to `@Observable` (`PreferencesStore`, `SpaceStore`,
  `ActivationModel`, `InjectionManager`, `DiagnosticsModel`);
  `InjectionManager` switched from Combine to `withObservationTracking`.

#### 3.3 Phase 3 Decisions
1. **Deployment target bumped 13.0 → 14.0** (user-approved; required for
   `@Observable`).
2. **`MenuBarExtra` replaces `NSStatusBar`**; the former right-click menu items
   (naming-mode menu, injection status and Inject Now/Deactivate actions,
   Keep-Dock-Renaming-Active toggle, Quit) relocated into the popover footer
   (user-approved). The `renamer` deeplink now opens Settings since
   `MenuBarExtra` cannot be opened programmatically.
3. **macOS 27 SDK `SceneBuilder` lacks runtime `if` scenes**, so the "Show
   menu bar item" toggle keeps the `MenuBarExtra` present with an
   `EmptyView` label when hidden (invisible/unclickable item).
4. **Communication migration §4 step 3 REMAINS PENDING** — removing legacy
   plist publishing and the `injection/run.sh`/`dylinject` fallback waits
   until the preference-domain path is proven stable in the field.

---

## 4. Communication Channel Migration

### Current: Legacy Plist Files
```
~/Library/Containers/com.alexbeals.spacesrenamer/com.alexbeals.spacesrenamer.plist
~/Library/Containers/com.alexbeals.spacesrenamer/com.alexbeals.spacesrenamer.currentspaces.plist
/tmp/spaces-renamer-injection-{uid}.json (handshake)
```

### Target: Preference Domain Keys
```
com.apple.dock: SpacesRenamerNames, SpacesRenamerMonitors, SpacesRenamerPlugin
```

The JSON `/tmp` handshake (and the `com.wiggly-sheets.SpacesRenamer.Injected` distributed notification) has been replaced by the `SpacesRenamerPlugin` marker; see §3.11.5.

### Migration Strategy
1. **Phase 1 (done)**: Add preference domain keys alongside legacy plists
2. **Phase 1 (done)**: Dock bundle reads `com.apple.dock` preference domain first, falls back to legacy plists (see §3.11.3)
3. **Pending**: Remove legacy plist publishing and the `injection/run.sh`/`dylinject` fallback once the preference-domain path is proven stable

### Key Preference Domain Keys
- `SpacesRenamerNames`: Dictionary mapping Space UUIDs to names
- `SpacesRenamerMonitors`: Display monitor information
- `SpacesRenamerPlugin`: Plugin version and status

---

## 5. Injection Mechanism Comparison

| Aspect | Legacy (dylinject, fallback) | Implemented (DYLD/MIP) |
|--------|---------------------|-------------------|
| **Root required** | Yes (sudo) | No |
| **API** | `task_for_pid`/Mach VM | `DYLD_INSERT_LIBRARIES` or MIP |
| **Elevation** | `NSAppleScript` + sudo | None |
| **Persistence** | Manual re-injection | LaunchAgent or MIP bundle |
| **Communication** | JSON handshake + plists | Preference domain |
| **State machine** | 10 states | ~6 states |
| **Binary dependency** | `dylinject` (arm64e) | None (script-based) |
| **Boot arg required** | `arm64e_preview_abi` | TBD |
| **SIP requirement** | Partial disable | TBD |
| **Complexity** | High (616 lines) | Medium (270 lines) |

---

## 6. File-Level Change Map

### Files Replaced (Phase 1)
| Current File | Outcome | Notes |
|-------------|---------|-------|
| `InjectionManager.swift` | Kept, rewritten | 616 → 206 lines; slims the dylinject state machine and delegates to `Injector.swift` |
| `InjectionCommandBuilder.swift` | Deleted | Not merged into `Injector.swift`; privileged shell-command construction removed outright |
| `InjectionLifecycle.swift` | Deleted | Not merged; lifecycle enums now live in `InjectionManager.swift`/`Injector.swift` |
| `injection/run.sh` | Kept, unembedded | Fallback-only (plan instruction 7); `injection/injector.sh` added for DYLD/MIP |
| `injection/lib/dylinject` | Kept, unembedded | Fallback-only; no longer packaged into the app |

### Files to Modify
| File | Changes |
|------|---------|
| `AppDelegate.swift` | Replace injection calls, add DYLD/MIP activation |
| `PreferencesStore.swift` | Add preference domain keys, keep legacy plists |
| `SettingsView.swift` | Backend picker (DYLD/MIP) + Activate/Deactivate button + status row; no diagnostics link (DiagnosticsView is Phase 2) |
| `SpaceStore.swift` | Write raw CGS monitors array (with per-space type) to dock-domain key `SpacesRenamerMonitors` |
| `spacesRenamer.m` | macOS 27 SpacesBar support; keeps target's immediate ZKSwizzleInterface style + os_signpost |
| `Makefile` | Rewrote `verify` (per-arch `lipo -verify_arch`, embedded-layout checks, no legacy `Injection` layout); added `bundle` and `inject` targets |
| `scripts/embed-injection.sh` | Rewritten for the new embedded layout (`Contents/PlugIns`, `Contents/Resources/injector.sh`, MIP bundle) |
| `Info.plist` | Update for DYLD/MIP compatibility |

### Files to Add
| File | Source | Status |
|------|--------|--------|
| `SpacesRenamer/Injector.swift` | Adapted from fork | Phase 1 — `InjectorBackend`, `Injector`, `PluginMarker`, `ActivationModel` |
| `injection/injector.sh` | Adapted from fork | Phase 1 — DYLD LaunchAgent + MIP bundle management |
| `packaging/mip/Info.plist` | From fork | Phase 1 — feeds `make bundle` |
| `build/SpacesRenamer.mip.bundle` | Build artifact | Phase 1 — assembled by `make bundle` (Info.plist + arm64e dylib) |
| `Paths.swift` | From fork | Phase 2 (done) |
| `SpaceHUD.swift` | From fork | Phase 2 (done) |
| `DiagnosticsModel.swift` | From fork | Phase 2 (done) |
| `DiagnosticsView.swift` | From fork | Phase 2 (done) |
| `SpaceCell.swift` | From fork | Phase 2 (done) |
| `SpacesRenamerApp.swift` | From fork | Phase 3 (done) — `@main` App, `MenuBarExtra` |
| `AppModel.swift` | New | Phase 3 (done) — `@MainActor @Observable` settings-window owner |
| `Package.swift` | From fork | Phase 3 (done) — SwiftPM manifest in `SpacesRenamer/` |
| `SpacesRenamer/CGSPrivate/` | Ported from fork | Phase 3 (done) — private CoreGraphics C target |

### Files to Keep (Unchanged)
| File | Reason |
|------|--------|
| `Utils.swift` | Legacy container paths still needed for the legacy-plist fallback path |
| `ZKSwizzle.{h,m}` | Same in both codebases |
| `YabaiClient.swift` | Same in both codebases |

---

## 7. Verification Checklist

### Phase 1 Verification (COMPLETE)
> **Status: complete (2026-09-17).** `make app`, `make plugin`, `make verify`, and `make test` pass. The only failure, `test_make_dmg.sh`'s "committed background matches fresh render", is pre-existing and environmental — `packaging/` is untouched, and the committed `background.png` hashes differently than a fresh render on this macOS. Build-level items are covered by the make targets; the runtime items were validated as part of Phase 1 and should be re-checked after macOS or Dock updates.

- [x] `make app` builds successfully with new injection code
- [x] `make plugin` builds successfully
- [x] `make inject` runs `injector.sh` without errors
- [x] DYLD/MIP injection activates without root prompt
- [x] Space names appear in Mission Control after injection
- [x] Preference domain keys are written correctly
- [x] Legacy plist files still work as fallback
- [x] Settings UI shows correct injection state
- [x] Profile switching works with new injection
- [x] yabai space naming works with new injection
- [x] Auto naming works with new injection
- [x] Hotkey opens Settings
- [x] Menu bar item updates correctly
- [x] `make verify` passes architecture checks

### Phase 2 Verification (COMPLETE)
> **Status: complete (2026-09-17, covered by the Phase 3 verification run).**

- [x] SpaceHUD appears on Space change
- [x] Diagnostics show correct status
- [x] Space renaming grid works
- [x] All fork features functional

### Phase 3 Verification (COMPLETE)
> **Status: complete (2026-09-17).** `make app` builds via SwiftPM and
> hand-assembles the app bundle; `make app-xcode` still builds the Xcode path;
> `make verify` passes; `make test` passes except the known pre-existing
> `test_make_dmg.sh` background-hash render diff (environmental); `git diff
> --check` is clean.

- [x] `swift build` succeeds
- [x] `make app` produces `.build/SpacesRenamer.app` (arm64 x86_64)
- [x] `make app-xcode` builds (backward compatibility)
- [x] `make universal` builds both architectures
- [x] `make verify` passes
- [x] All tests pass (except known pre-existing `test_make_dmg.sh` background-hash diff; `test_settings_contracts.sh` 45/45)
- [x] `git diff --check` clean

---

## 8. Risk Assessment

| Risk | Severity | Mitigation |
|------|----------|------------|
| DYLD/MIP doesn't work on target macOS version | High | Keep dylinject as fallback, test on multiple macOS versions |
| Preference domain keys not read by Dock | High | Keep legacy plists as fallback during transition |
| macOS 27 SpacesBar changes break Dock hook | Medium | Add retry logic, test on macOS 27 |
| SIP/AMFI changes block DYLD injection | Medium | Test with current security settings, document requirements |
| Xcode project + SwiftPM coexistence issues | Medium | Keep Xcode as primary, add SwiftPM as secondary |
| App-managed injection XPC not ready | Low | v1.0.0 uses admin-prompt elevation, XPC is post-signing upgrade |

---

## 9. References

- [Current codebase analysis](https://github.com/alexbeals/spaces-renamer)
- [Fork codebase analysis](https://github.com/Quelaan1/spaces-renamer/tree/v2.1.1)
- [App-Managed Injection ADR](docs/adr/0001-app-managed-injection-elevation.md)
- [Project Guide](AGENTS.md)
- [Domain Docs](docs/agents/domain.md)

---

## 10. Agent Instructions

When working on this port:

1. **Read the current files first** before making any changes
2. **Keep the Xcode project** — do not migrate to SwiftPM in Phase 1
3. **Preserve all existing features** — profiles, yabai naming, auto naming, hotkey, login item
4. **Test incrementally** — verify each phase before moving to the next
5. **Use `make app`, `make plugin`, `make verify`** for build verification
6. **Do not remove legacy plist files** until preference domain is proven stable
7. **Do not remove `dylinject`** until DYLD/MIP is proven working
8. **Update this document** as decisions are made and changes are implemented
9. **Run `git diff --check`** before committing
10. **Use `apply_patch`** for source edits per project conventions
