// Renders packaging/background.png for the Spaces Renamer DMG.
//
// Usage: swift render-background.swift [OUTPUT]
//
// Placeholder artwork: a plain white-to-grey gradient with the app name and
// "Drag to Applications" instructions baked in, so the volume shows the app
// and the install target with no stray files (no extra volume icons or
// readmes). Coordinates use the same bottom-left origin create-dmg passes to
// Finder (window 800x450, app icon at 200,190, Applications drop-link at
// 600,190). The volume icon name is already visible under the app icon in
// Finder, so the artwork does not repeat it.
//
// Output is deterministic: drawn into a fixed 1600x900 (2x) bitmap
// regardless of the display the build machine has, so regenerating always
// produces the same pixels. The generated PNG is committed; regeneration is
// only needed when the layout changes.

import AppKit

let outputPath = CommandLine.arguments.count > 1
  ? CommandLine.arguments[1]
  : "background.png"

let width: CGFloat = 800
let height: CGFloat = 450
let scale: CGFloat = 2

guard let rep = NSBitmapImageRep(
  bitmapDataPlanes: nil,
  pixelsWide: Int(width * scale),
  pixelsHigh: Int(height * scale),
  bitsPerSample: 8,
  samplesPerPixel: 4,
  hasAlpha: true,
  isPlanar: false,
  colorSpaceName: .deviceRGB,
  bytesPerRow: 0,
  bitsPerPixel: 0
) else {
  fatalError("failed to create bitmap")
}
// Point size of the drawing surface; the context maps these points onto the
// 1600x900 pixel grid above.
rep.size = NSSize(width: width, height: height)

guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
  fatalError("failed to create graphics context")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
defer {
  ctx.flushGraphics()
  NSGraphicsContext.restoreGraphicsState()
}

let cg = ctx.cgContext

// Background gradient: light grey at the bottom to white at the top.
let colors = [
  NSColor(calibratedWhite: 0.92, alpha: 1).cgColor,
  NSColor(calibratedWhite: 0.98, alpha: 1).cgColor,
] as CFArray
let gradient = CGGradient(
  colorsSpace: CGColorSpaceCreateDeviceRGB(),
  colors: colors,
  locations: [0, 1]
)!
cg.drawLinearGradient(
  gradient,
  start: CGPoint(x: 0, y: 0),
  end: CGPoint(x: 0, y: height),
  options: []
)

func drawCentered(_ text: String, font: NSFont, color: NSColor, center: NSPoint) {
  let attributes: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: color,
  ]
  let string = text as NSString
  let textSize = string.size(withAttributes: attributes)
  string.draw(
    at: NSPoint(
      x: center.x - textSize.width / 2,
      y: center.y - textSize.height / 2
    ),
    withAttributes: attributes
  )
}

// Title.
drawCentered(
  "Spaces Renamer",
  font: .systemFont(ofSize: 32, weight: .semibold),
  color: NSColor(calibratedWhite: 0.25, alpha: 1),
  center: NSPoint(x: width / 2, y: 400)
)

// Applications drop zone on the right, centered on the drop-link position.
let dropCenter = NSPoint(x: 600, y: 190)
let dropRect = CGRect(
  x: dropCenter.x - 90,
  y: dropCenter.y - 85,
  width: 180,
  height: 170
)
cg.setStrokeColor(NSColor(calibratedWhite: 0.55, alpha: 1).cgColor)
cg.setLineWidth(2)
cg.setLineDash(phase: 0, lengths: [8, 5])
cg.stroke(dropRect)

// Instruction text, centered between the app icon (200) and the Applications
// drop-link (600).
drawCentered(
  "Drag to Applications",
  font: .systemFont(ofSize: 18, weight: .regular),
  color: NSColor(calibratedWhite: 0.35, alpha: 1),
  center: NSPoint(x: 400, y: 190)
)

// Arrow below the text pointing to the Applications drop zone on the right.
let arrowY: CGFloat = 115
let arrowStartX: CGFloat = 300
let arrowEndX: CGFloat = 500
cg.setStrokeColor(NSColor(calibratedWhite: 0.55, alpha: 1).cgColor)
cg.setLineWidth(3)
cg.move(to: CGPoint(x: arrowStartX, y: arrowY))
cg.addLine(to: CGPoint(x: arrowEndX, y: arrowY))
cg.strokePath()
cg.setFillColor(NSColor(calibratedWhite: 0.55, alpha: 1).cgColor)
cg.move(to: CGPoint(x: arrowEndX, y: arrowY))
cg.addLine(to: CGPoint(x: arrowEndX - 15, y: arrowY - 7))
cg.addLine(to: CGPoint(x: arrowEndX - 15, y: arrowY + 7))
cg.closePath()
cg.fillPath()

guard let png = rep.representation(using: .png, properties: [:]) else {
  fatalError("failed to encode PNG")
}
try! png.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath)")
