import CoreGraphics

// Private SkyLight symbols that read the Spaces layout. Declared here instead of in a C target so
// the app stays Swift-only; CoreGraphics re-exports them, so the linker resolves them there.
@_silgen_name("_CGSDefaultConnection")
func _CGSDefaultConnection() -> Int32

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> CFArray
