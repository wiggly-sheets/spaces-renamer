# App-managed injection uses system admin-prompt elevation; privileged helper deferred

Spaces Renamer needs the GUI app to drive Dock injection for an all-in-one v1.0.0 workflow. The documented design called for an `SMAppService` launch daemon with a scoped XPC interface, but launchd privileged-helper installation requires a Developer ID Application certificate, and none is currently available (only an Apple Development identity). We chose to embed the existing injection stack (`run.sh`, `dylinject`, `spaces-renamer.dylib`) inside the app bundle and elevate via `osascript` `do shell script ... with administrator privileges`, which shows the system password / Touch ID dialog.

This keeps the exact security posture of the current standalone `injection/run.sh` (a sudo prompt) with no new trust boundary, no deprecated `AuthorizationExecuteWithPrivileges`, and no broad sudoers rule. The trade-off: the injected code is readable inside the app bundle (accepted — the tool already requires reduced security protections), and every privileged run needs the system dialog (accepted — it is the consent the user grants once and persists).

The `SMAppService` daemon + scoped-XPC helper remains the designed post-signing upgrade path once a Developer ID identity exists. It was not dropped for technical reasons, only deferred by the signing constraint.
