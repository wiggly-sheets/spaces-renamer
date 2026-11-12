import SwiftUI

/// Native Liquid Glass for the app UI (macOS 26+) with a material fallback for
/// the older systems the app still supports.
public extension View {
  /// Groups descendant glass effects into one system render pass.
  ///
  /// On macOS 26+ the container batches similar glass and, at a positive
  /// `spacing`, merges adjacent glass. A spacing of zero keeps cards distinct
  /// while still avoiding one sampling pass per card. Older systems render the
  /// content unchanged.
  @ViewBuilder
  func glassEffectContainer(spacing: CGFloat = 0) -> some View {
    if #available(macOS 26.0, *) {
      GlassEffectContainer(spacing: spacing) { self }
    } else {
      self
    }
  }

  /// Applies the native Liquid Glass material to this view's background.
  ///
  /// - Parameters:
  ///   - shape: The glass shape.
  ///   - fallbackMaterial: The material used before macOS 26.
  ///   - interactive: Requests the system's press/hover response. Use it for
  ///     surfaces that contain controls, not for passive content cards.
  @ViewBuilder
  func glassBackground(
    in shape: some Shape,
    fallbackMaterial: some ShapeStyle = Material.regularMaterial,
    interactive: Bool = false
  ) -> some View {
    if #available(macOS 26.0, *) {
      self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
    } else {
      self.background(fallbackMaterial, in: shape)
        .overlay(shape.stroke(.quaternary, lineWidth: 0.5))
    }
  }
}
