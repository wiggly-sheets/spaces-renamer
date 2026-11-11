import SwiftUI

/// Applies the macOS 26+ Liquid Glass effect when available and falls back
/// to a configurable material card on older systems.
public extension View {
  @ViewBuilder
  func glassBackground(
    in shape: some Shape,
    fallbackMaterial: some ShapeStyle = Material.regularMaterial
  ) -> some View {
    if #available(macOS 26.0, *) {
      self.glassEffect(in: shape)
    } else {
      self.background(fallbackMaterial, in: shape)
        .overlay(shape.stroke(.quaternary, lineWidth: 0.5))
    }
  }
}