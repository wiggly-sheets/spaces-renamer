# Spaces Renamer

Spaces Renamer gives macOS Spaces persistent, useful names in Mission Control. A SwiftUI menu-bar app holds names and state; an Objective-C bundle injected into Dock renders the labels.

## Language

**Space**:
A macOS virtual desktop shown in Mission Control. Each Space has a stable, unique UUID used as the key across the app.
_Avoid_: Desktop, workspace

**Space name**:
The persistent, user-facing identity a Space has been given — stored per profile, keyed by Space UUID. May be manual or generated.
_Avoid_: Title, custom label

**Space label**:
The text Mission Control renders for a Space: its Space name when one is set, or macOS's default otherwise. The injected Dock bundle renders labels; it does not own names.
_Avoid_: Space text, name tag

**Profile**:
An independent mapping of Space UUIDs to Space names. Work and Home ship by default. Switching profiles republishes the active mapping to Dock immediately.
_Avoid_: Workspace, preset

**Naming mode**:
The strategy that produces a Space's name: Manual (the active profile), Apps in Space (visible windows, requires yabai), or yabai Space Labels.
_Avoid_: Name source, naming method

**Injection**:
Loading the spaces-renamer bundle into Dock so it can replace Mission Control's label rendering.
_Avoid_: Install, hook

**App-managed injection**:
Injection driven by the GUI app itself — payload embedded in the app bundle, elevated through the system admin prompt — rather than by the standalone `injection/` script.
_Avoid_: Privileged helper (that is the separate, post-signing design)

**Consent**:
The user's grant, given at first launch, authorizing the app to inject into Dock. Persists across launches; revocation or failure returns the app to manual re-inject buttons.
_Avoid_: Authorization, permission (overloaded in Apple's APIs)
